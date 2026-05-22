# Requirements:

    这个项目的目的实现与Unibuy协议配套的UnibuyOrderManager智能合约；
    + UniBuy协议的功能描述文档为：/UnibuyNew/docs/UnibuyCn.md 和 /UnibuyNew/docs/UnibuyEn.md。
    + UniBuy协议的实现代码为：/UnibuyNew/src/UnibuyPoolManager.sol。
    + UnibuyOrderManager 的主要功能是为用户提供订单服务，用户的订单分为一下几类：
        1. 吃单：吃单是可以立即成交的订单，从用户使用体验上看直观可以分为买入吃单和买车出吃单。买入吃单是用户给定token0或token1的数量，以及买入的最高限价；最高限价不得低于交易对的当前价格，否则无法成交，异常返回；卖出吃单是用户给定token0或token1的数量，以及卖出的最低限价；最低限价不得高于交易对的当前价格，否则无法成交，异常返回。本质上，买入吃单和买出吃单是一回事，一个Pool的买入吃单，就是这个Pool的镜像Pool的卖出吃单；
        2. 挂单：挂单是无法立即成交的用户订单，挂单从用户使用体验上看直观可以分为买入挂单和买出挂单。买入挂单是用户给定token0或token1的数量，以及买入的最高限价；最高限价不得高于交易对的当前价格，导致交易无法立即成交，需要按照挂单处理，等待吃单成交；卖出挂单是用户给定token0或token1的数量，以及卖出的最低限价；最低限价不得低于交易对的当前价格，导致无法立即成交，需要按照挂单处理，等待吃单成交。本质上买入挂单和买出挂单是一回事，一个Pool的买入挂单，就是这个Pool的镜像Pool的卖出挂单；
        3. 先吃单，后挂单：如果用户给出订单的价格范围有一部分可以立即成交，那就先按照吃单处理，这部分可以成交的价格范围，未成交部分按照挂单处理；
    + UnibuyOrderManager 的吃单处理逻辑可以参照 /UnibuyNew/v4-periphery/src/V4Router.sol的Swap功能实现；
    + UnibuyOrderManager 的挂单处理逻辑可以参照 /UnibuyNew/v4-periphery/src/PositionManager.sol的 Position 功能实现；用户的挂单可以利用NFT ID唯一标识； 
    + 需要创建完整的挂单、吃单的测试案例；
    + /UnibuyNew/下的代码仅作为参考不要修改；



 