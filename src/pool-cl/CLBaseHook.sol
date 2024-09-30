// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_AFTER_DONATE_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET
} from "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "pancake-v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLHooks} from "pancake-v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "./ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";

abstract contract CLBaseHook is ICLHooks {
    error NotPoolManager();
    error NotVault();
    error NotSelf();
    error InvalidPool();
    error LockFailure();
    error HookNotImplemented();

    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnsDelta;
        bool afterSwapReturnsDelta;
        bool afterAddLiquidityReturnsDelta;
        bool afterRemoveLiquidityReturnsDelta;
    }

    enum OrderType {
        STOP_LOSS,
        BUY_STOP,
        BUY_LIMIT,
        TAKE_PROFIT
    }
    enum OrderStatus {
        OPEN,
        EXECUTED,
        CANCELED
    }

    struct Order {
        bytes32 id;
        address user;
        OrderType orderType;
        uint256 amountIn;
        int24 triggerTick;
        OrderStatus status;
        bool zeroForOne;
    }

    uint256 public orderCount;
    PoolKey public poolKey;
    mapping(bytes32 => Order) public orders;
    mapping(int24 tick => mapping(bool zeroForOne => Order[])) public orderPositions;
    mapping(PoolId => int24) public tickLowerLasts;
    mapping(address userAddress => Order[]) public userOrders;

    event OrderPlaced(
        bytes32 indexed orderId, address indexed user, OrderType orderType, uint256 amountIn, int24 triggerPrice
    );
    event OrderExecuted(
        bytes32 indexed orderId, address indexed user, OrderType orderType, uint256 amountIn, int24 triggerPrice
    );
    event OrderCanceled(bytes32 indexed orderId, address indexed user, OrderType orderType);

    event OrdersProcessed(bytes32[] orderIds);

    function placeOrder(
        OrderType orderType,
        uint256 amountIn,
        int24 _triggerTick,
        PoolKey calldata _poolKey,
        int24 tickLower
    ) external returns (bytes32 orderId) {
        require(amountIn > 0, "Amount must be greater than 0");

        orderId = keccak256(abi.encodePacked(orderCount, msg.sender, block.timestamp));
        bool zeroForOne = (orderType == OrderType.BUY_STOP) || (orderType == OrderType.STOP_LOSS);
        orders[orderId] = Order({
            id: orderId,
            user: msg.sender,
            orderType: orderType,
            amountIn: amountIn,
            triggerTick: _triggerTick,
            status: OrderStatus.OPEN,
            zeroForOne: zeroForOne
        });
        int24 tick = getTickLower(tickLower, _poolKey.tickSpacing);
        orderPositions[tick][zeroForOne].push(orders[orderId]);
        userOrders[msg.sender].push(orders[orderId]);
        orderCount++;

        // Transfer token0 to this contract
        address token = zeroForOne ? Currency.unwrap(_poolKey.currency0) : Currency.unwrap(_poolKey.currency1);
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);
        emit OrderPlaced(orderId, msg.sender, orderType, amountIn, _triggerTick);
    }

    function getOrder(bytes32 orderId) external view returns (Order memory) {
        return orders[orderId];
    }

    function cancelOrder(bytes32 orderId) external {
        Order storage order = orders[orderId];
        require(order.user == msg.sender, "Only the order creator can cancel the order");
        require(order.status == OrderStatus.OPEN, "Order can only be canceled if it is open");

        // Update order status to canceled
        order.status = OrderStatus.CANCELED;

        // Transfer the tokens back to the user
        address token = order.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        IERC20(token).transfer(order.user, order.amountIn);

        emit OrderCanceled(orderId, msg.sender, order.orderType);
    }

    /// @notice The address of the pool manager
    ICLPoolManager public immutable poolManager;

    /// @notice The address of the vault
    IVault public immutable vault;

    constructor(ICLPoolManager _poolManager) {
        poolManager = _poolManager;
        vault = CLPoolManager(address(poolManager)).vault();
    }

    /// @dev Only the pool manager may call this function
    modifier poolManagerOnly() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @dev Only the vault may call this function
    modifier vaultOnly() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    /// @dev Only this address may call this function
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @dev Only pools with hooks set to this contract may call this function
    modifier onlyValidPools(IHooks hooks) {
        if (address(hooks) != address(this)) revert InvalidPool();
        _;
    }

    /// @dev Helper function when the hook needs to get a lock from the vault. See
    ///      https://github.com/pancakeswap/pancake-v4-hooks oh hooks which perform vault.lock()
    function lockAcquired(bytes calldata data) external virtual vaultOnly returns (bytes memory) {
        (bool success, bytes memory returnData) = address(this).call(data);
        if (success) return returnData;
        if (returnData.length == 0) revert LockFailure();
        // if the call failed, bubble up the reason
        /// @solidity memory-safe-assembly
        assembly {
            revert(add(returnData, 32), mload(returnData))
        }
    }

    function beforeInitialize(address, PoolKey calldata, uint160, bytes calldata) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual returns (bytes4) {

    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        virtual
        returns (bytes4, int128)
    {
        int24 prevTick = tickLowerLasts[key.toId()];
        int24 tick = getTick(key.toId());
        int24 currentTick = getTickLower(tick, key.tickSpacing);
        tick = prevTick;

        Order[] memory validOrders;
        // fill orders in the opposite direction of the swap
        bool orderZeroForOne = !params.zeroForOne;

        if (prevTick < currentTick) {
            for (; tick < currentTick;) {
                validOrders = orderPositions[tick][orderZeroForOne];

                bytes32[] memory orderIds = new bytes32[](validOrders.length);
                uint256 index = 0;
                for (uint256 i = 0; i < validOrders.length; i++) {
                    orderIds[index] = validOrders[i].id;
                    index++;
                }
                if (orderIds.length > 0) {
                    emit OrdersProcessed(orderIds);
                }
                unchecked {
                    tick += key.tickSpacing;
                }
            }
        } else {
            for (; currentTick < tick;) {
                validOrders = orderPositions[tick][orderZeroForOne];
                bytes32[] memory orderIds = new bytes32[](validOrders.length);
                uint256 index = 0;
                for (uint256 i = 0; i < validOrders.length; i++) {
                    orderIds[index] = validOrders[i].id;
                    index++;
                }
                if (orderIds.length > 0) {
                    emit OrdersProcessed(orderIds);
                }
                unchecked {
                    tick -= key.tickSpacing;
                }
            }
        }
        return (AdvancedOrders.afterSwap.selector, 0);
    }

    function settleOrder(bytes32 orderId, bytes calldata _extraData) external {
        // TODO: add modifier
        Order storage order = orders[orderId];
        int24 currentTick = getTick(poolKey.toId());

        if (!shouldExecuteOrder(order, currentTick)) {
            revert("order can not be filled");
        }

        address tokenIn = !order.zeroForOne ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);
        address tokenOut = !order.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        IERC20(tokenIn).transfer(msg.sender, order.amountIn);

        (bool success,) = msg.sender.call(
            abi.encodeWithSignature("settleCallback(address,address,bytes)", tokenIn, tokenOut, _extraData)
        );

        order.status = OrderStatus.EXECUTED;
        IERC20(tokenOut).transfer(order.user, IERC20(tokenOut).balanceOf(address(this)));
    }

    function shouldExecuteOrder(Order storage order, int24 currentTick) internal view returns (bool) {
        if (order.orderType == OrderType.STOP_LOSS && currentTick <= order.triggerTick) {
            return true;
        } else if (order.orderType == OrderType.BUY_STOP && currentTick >= order.triggerTick) {
            return true;
        } else if (order.orderType == OrderType.BUY_LIMIT && currentTick <= order.triggerTick) {
            return true;
        } else if (order.orderType == OrderType.TAKE_PROFIT && currentTick >= order.triggerTick) {
            return true;
        }
        return false;
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _hooksRegistrationBitmapFrom(Permissions memory permissions) internal pure returns (uint16) {
        return uint16(
            (permissions.beforeInitialize ? 1 << HOOKS_BEFORE_INITIALIZE_OFFSET : 0)
                | (permissions.afterInitialize ? 1 << HOOKS_AFTER_INITIALIZE_OFFSET : 0)
                | (permissions.beforeAddLiquidity ? 1 << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET : 0)
                | (permissions.afterAddLiquidity ? 1 << HOOKS_AFTER_ADD_LIQUIDITY_OFFSET : 0)
                | (permissions.beforeRemoveLiquidity ? 1 << HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET : 0)
                | (permissions.afterRemoveLiquidity ? 1 << HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET : 0)
                | (permissions.beforeSwap ? 1 << HOOKS_BEFORE_SWAP_OFFSET : 0)
                | (permissions.afterSwap ? 1 << HOOKS_AFTER_SWAP_OFFSET : 0)
                | (permissions.beforeDonate ? 1 << HOOKS_BEFORE_DONATE_OFFSET : 0)
                | (permissions.afterDonate ? 1 << HOOKS_AFTER_DONATE_OFFSET : 0)
                | (permissions.beforeSwapReturnsDelta ? 1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterSwapReturnsDelta ? 1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterAddLiquidityReturnsDelta ? 1 << HOOKS_AFTER_ADD_LIQUIDIY_RETURNS_DELTA_OFFSET : 0)
                | (permissions.afterRemoveLiquidityReturnsDelta ? 1 << HOOKS_AFTER_REMOVE_LIQUIDIY_RETURNS_DELTA_OFFSET : 0)
        );
    }
}
