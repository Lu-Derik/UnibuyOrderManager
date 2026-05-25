// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {OrderManagerTestBase} from "./helpers/OrderManagerTestBase.t.sol";
import {UnibuyOrderManager}   from "../src/UnibuyOrderManager.sol";
import {ERC721PermitHash}     from "../src/libraries/ERC721PermitHash.sol";

import {UnibuyPoolKey, UnibuyPoolId, UnibuyPoolIdLibrary} from "@unibuy/types/UnibuyPoolKey.sol";
import {Currency, CurrencyLibrary} from "@unibuy/types/Currency.sol";
import {TickMath}        from "@unibuy/libraries/TickMath.sol";
import {IProtocolFees}   from "@unibuy/interfaces/IProtocolFees.sol";
import {PoolFeeLibrary}  from "@unibuy/libraries/PoolFeeLibrary.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Helper: malicious ERC-20 that attempts a reentrant call into orderManager
// during its transferFrom hook.  Used to verify the `isNotLocked` guard.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Which orderManager entry-point the hook will attempt to re-enter.
enum AttackType { TAKER_ORDER, PLACE_MAKER_ORDER, CLOSE_MAKER_ORDER, MIXED_ORDER }

contract ReentrantERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals;
    uint256 public totalSupply;

    mapping(address => uint256)                       public balanceOf;
    mapping(address => mapping(address => uint256))   public allowance;

    event Transfer(address indexed from, address indexed to,    uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    UnibuyOrderManager public target;
    UnibuyPoolKey      public attackKey;        // pool to pass to the reentrant call
    AttackType         public attackType;
    bool               private _inHook;

    /// @notice Set to true when the reentrant call reverted with ContractLocked.
    bool public reentrantCallReverted;

    constructor(string memory _name, string memory _symbol) {
        name     = _name;
        symbol   = _symbol;
        decimals = 18;
    }

    function setTarget(
        UnibuyOrderManager  _target,
        UnibuyPoolKey calldata _key,
        AttackType            _type
    ) external {
        target     = _target;
        attackKey  = _key;
        attackType = _type;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transferRaw(msg.sender, to, amount);
        return true;
    }

    /// @dev The hook fires after the transfer completes to simulate a reentrant attack.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ReentrantERC20: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transferRaw(from, to, amount);

        if (_inHook || address(target) == address(0)) return true;
        _inHook = true;

        bytes memory revertData;
        bool success;

        if (attackType == AttackType.TAKER_ORDER) {
            (success, revertData) = address(target).call(
                abi.encodeCall(
                    target.takeOrderInputSingle,
                    (attackKey, from, 1, 0, type(uint160).max, block.timestamp + 1 hours)
                )
            );
        } else if (attackType == AttackType.PLACE_MAKER_ORDER) {
            (success, revertData) = address(target).call(
                abi.encodeCall(
                    target.placeOrderNoTake,
                    (attackKey, int24(60), int24(120), uint128(1), block.timestamp + 1 hours)
                )
            );
        } else if (attackType == AttackType.CLOSE_MAKER_ORDER) {
            // tokenId 9999 likely doesn't exist, but ContractLocked fires first
            (success, revertData) = address(target).call(
                abi.encodeCall(
                    target.closeMakerOrder,
                    (9999, attackKey, block.timestamp + 1 hours)
                )
            );
        } else if (attackType == AttackType.MIXED_ORDER) {
            (success, revertData) = address(target).call(
                abi.encodeCall(
                    target.mixedOrder,
                    (attackKey, 0, type(uint160).max, attackKey, int24(60), int24(120), uint128(0), from, block.timestamp + 1 hours)
                )
            );
        }

        if (!success && revertData.length >= 4) {
            bytes4 sel;
            assembly { sel := mload(add(revertData, 32)) }
            if (sel == bytes4(keccak256("ContractLocked()"))) {
                reentrantCallReverted = true;
            }
        }

        _inHook = false;
        return true;
    }

    function _transferRaw(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ReentrantERC20: balance");
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Security / regression tests for the 4 fixed issues
// ─────────────────────────────────────────────────────────────────────────────
contract SecurityTest is OrderManagerTestBase {
    using UnibuyPoolIdLibrary for UnibuyPoolKey;

    int24   constant TL  = 60;
    int24   constant TU  = 180;
    uint128 constant LIQ = 10e18;

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploy a pool whose currency1 is a ReentrantERC20, place a sell
    ///      order to seed liquidity, then have `dave` call takerOrder to trigger
    ///      the reentrant hook.  Returns the malicious token so the caller can
    ///      inspect `reentrantCallReverted`.
    function _setupAndAttack(AttackType at) internal returns (ReentrantERC20 mal) {
        mal = new ReentrantERC20("MalToken", "MAL");
        // Attack using the main tokenA/tokenB pool key — the hook just needs to call
        // *any* orderManager entry-point to hit the ContractLocked check.
        mal.setTarget(orderManager, poolKey, at);

        // Pool: currency0=tokenA  currency1=malToken
        UnibuyPoolKey memory malPool = UnibuyPoolKey({
            currency0:  Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(mal)),
            tickSpacing: TICK_SPACING
        });

        poolManager.initialize(malPool, SQRT_PRICE_1_1);

        // Seed liquidity: Alice places a sell order (deposits tokenA)
        tokenA.mint(alice, 1_000_000 ether);
        vm.prank(alice);
        tokenA.approve(address(orderManager), type(uint256).max);
        vm.prank(alice);
        orderManager.placeOrderNoTake(
            malPool, TL, TU, uint128(LIQ), block.timestamp + 1 hours
        );

        // Attacker (dave) gets malToken and approves orderManager
        mal.mint(dave, 1_000_000 ether);
        vm.prank(dave);
        mal.approve(address(orderManager), type(uint256).max);

        // Dave buys tokenA by paying malToken — triggers transferFrom hook
        vm.prank(dave);
        orderManager.takeOrderInputSingle(
            malPool,
            dave,              // recipient
            1e15,
            0,                 // amountOutMinimum — no guard
            TickMath.getSqrtPriceAtTick(TU),
            block.timestamp + 1 hours
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fix #1 + #2 — Locker non-zero slot & isNotLocked applied to all entry points
    //
    // Each test exercises a different entry-point as the target of the reentrant
    // call.  ContractLocked must be returned for ALL four functions, proving that
    // (a) the lock mechanism works and (b) isNotLocked guards every entry point.
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Reentrant call to takerOrder is blocked.
    function test_isNotLocked_takerOrder_blocksReentrant() public {
        ReentrantERC20 mal = _setupAndAttack(AttackType.TAKER_ORDER);
        assertTrue(mal.reentrantCallReverted(), "takerOrder: expected ContractLocked on reentrant call");
    }

    /// @dev Reentrant call to placeMakerOrder is blocked.
    function test_isNotLocked_placeMakerOrder_blocksReentrant() public {
        ReentrantERC20 mal = _setupAndAttack(AttackType.PLACE_MAKER_ORDER);
        assertTrue(mal.reentrantCallReverted(), "placeMakerOrder: expected ContractLocked on reentrant call");
    }

    /// @dev Reentrant call to closeMakerOrder is blocked.
    function test_isNotLocked_closeMakerOrder_blocksReentrant() public {
        ReentrantERC20 mal = _setupAndAttack(AttackType.CLOSE_MAKER_ORDER);
        assertTrue(mal.reentrantCallReverted(), "closeMakerOrder: expected ContractLocked on reentrant call");
    }

    /// @dev Reentrant call to mixedOrder is blocked.
    function test_isNotLocked_mixedOrder_blocksReentrant() public {
        ReentrantERC20 mal = _setupAndAttack(AttackType.MIXED_ORDER);
        assertTrue(mal.reentrantCallReverted(), "mixedOrder: expected ContractLocked on reentrant call");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fix #3 — closeMakerOrder now uses _isApprovedOrOwner
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Operator approved via approve() for a specific token can close it.
    function test_fix3_approve_allowsClose() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        // Alice approves bob for this specific tokenId
        vm.prank(alice);
        orderManager.approve(bob, tokenId);
        assertEq(orderManager.getApproved(tokenId), bob);

        // Bob closes alice's order
        vm.startPrank(bob);
        uint256 t0Before = tokenA.balanceOf(bob);
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp + 1 hours);
        vm.stopPrank();
        uint256 t0 = tokenA.balanceOf(bob) - t0Before;
        assertGt(t0, 0, "approved operator should receive token0");
        assertEq(tokenA.balanceOf(bob), t0Before + t0, "bob balance should increase");

        // NFT must be burned
        vm.expectRevert();
        orderManager.ownerOf(tokenId);
    }

    /// @dev Operator approved via setApprovalForAll() can close any of owner's tokens.
    function test_fix3_setApprovalForAll_allowsClose() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        // Alice grants carol operator rights over ALL her tokens
        vm.prank(alice);
        orderManager.setApprovalForAll(carol, true);
        assertTrue(orderManager.isApprovedForAll(alice, carol));

        // Carol closes alice's order
        vm.startPrank(carol);
        uint256 t0Before = tokenA.balanceOf(carol);
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp + 1 hours);
        vm.stopPrank();
        uint256 t0 = tokenA.balanceOf(carol) - t0Before;
        assertGt(t0, 0, "operator-for-all should receive token0");

        // NFT must be burned
        vm.expectRevert();
        orderManager.ownerOf(tokenId);
    }

    /// @dev Permit signature from the owner grants a spender the right to close.
    function test_fix3_permit_allowsClose() public {
        // Create a fresh alice with a known private key (makeAddr uses a fixed derivation)
        (address aliceSigner, uint256 alicePk) = makeAddrAndKey("alice_signer");
        tokenA.mint(aliceSigner, 1_000_000 ether);
        vm.prank(aliceSigner);
        tokenA.approve(address(orderManager), type(uint256).max);

        // Place order as aliceSigner
        uint256 tokenId = orderManager.nextTokenId();
        vm.prank(aliceSigner);
        orderManager.placeOrderNoTake(poolKey, TL, TU, uint128(LIQ), block.timestamp + 1 hours);
        assertEq(orderManager.ownerOf(tokenId), aliceSigner);

        // aliceSigner signs a permit allowing bob to manage tokenId
        uint256 nonce    = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = ERC721PermitHash.hashPermit(bob, tokenId, nonce, deadline);
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", orderManager.DOMAIN_SEPARATOR(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        bytes memory sig = abi.encodePacked(r, s, v); // 65-byte compact signature

        // Anyone can submit the permit
        orderManager.permit(bob, tokenId, deadline, nonce, sig);
        assertEq(orderManager.getApproved(tokenId), bob, "permit should set approval");

        // Bob can now close the order
        vm.startPrank(bob);
        uint256 t0Before = tokenA.balanceOf(bob);
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp + 1 hours);
        vm.stopPrank();
        uint256 t0 = tokenA.balanceOf(bob) - t0Before;
        assertGt(t0, 0, "permit-approved spender should receive token0");
    }

    /// @dev A caller with no approval cannot close — must revert with NotTokenOwner.
    function test_fix3_notApproved_reverts() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("NotTokenOwner(address,address)")),
                dave,
                alice
            )
        );
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp + 1 hours);
    }

    /// @dev Approval granted then revoked via setApprovalForAll should NOT allow close.
    function test_fix3_revokedApprovalForAll_reverts() public {
        (uint256 tokenId,) = _placeSellOrder(alice, TL, TU, LIQ);

        vm.startPrank(alice);
        orderManager.setApprovalForAll(carol, true);
        orderManager.setApprovalForAll(carol, false); // revoke
        vm.stopPrank();

        assertFalse(orderManager.isApprovedForAll(alice, carol));

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("NotTokenOwner(address,address)")),
                carol,
                alice
            )
        );
        orderManager.closeMakerOrder(tokenId, poolKey, block.timestamp + 1 hours);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fix #4 — DeltaResolver._settle forwards ETH for native-currency pools
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Taker pays native ETH → _settle must call poolManager.settle{value}.
    ///      Pool layout: currency0=tokenA  currency1=ETH(address(0)).
    function test_fix4_nativeETH_takerOrder() public {
        // ── Setup: create a native-ETH pool ──────────────────────────────────
        UnibuyPoolKey memory nativePool = UnibuyPoolKey({
            currency0:  Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(0)),   // native ETH
            tickSpacing: TICK_SPACING
        });
        poolManager.initialize(nativePool, SQRT_PRICE_1_1);

        // ── Seed: Alice deposits tokenA as a sell-order maker ─────────────────
        tokenA.mint(alice, 1_000_000 ether);
        vm.prank(alice);
        tokenA.approve(address(orderManager), type(uint256).max);
        vm.prank(alice);
        orderManager.placeOrderNoTake(
            nativePool, TL, TU, uint128(LIQ), block.timestamp + 1 hours
        );

        // ── Taker: Dave buys tokenA by paying native ETH ──────────────────────
        uint256 ethAmount    = 1e15;
        vm.deal(dave, ethAmount);

        uint256 daveTkABefore  = tokenA.balanceOf(dave);
        uint256 daveEthBefore  = address(dave).balance;

        vm.prank(dave);
        orderManager.takeOrderInputSingle{value: ethAmount}(
            nativePool,
            dave,
            ethAmount,
            0,                               // amountOutMinimum — no guard
            TickMath.getSqrtPriceAtTick(TU),
            block.timestamp + 1 hours
        );
        uint256 amtOut = tokenA.balanceOf(dave) - daveTkABefore;
        uint256 amtIn = daveEthBefore - address(dave).balance;

        // ── Assertions ────────────────────────────────────────────────────────
        assertGt(amtOut, 0,                    "taker should receive tokenA");
        assertGt(amtIn,  0,                    "taker should spend ETH");
        assertEq(
            tokenA.balanceOf(dave),
            daveTkABefore + amtOut,
            "dave tokenA balance mismatch"
        );
        assertEq(
            address(dave).balance,
            daveEthBefore - amtIn,
            "dave ETH balance mismatch"
        );
    }
}
