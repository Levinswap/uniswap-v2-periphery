pragma solidity =0.5.16;

import './interfaces/V2/IUniswapV2Callee.sol';
import './UniswapV2Library.sol';
import './interfaces/V1/IUniswapV1Factory.sol';
import './interfaces/V1/IUniswapV1Exchange.sol';
import './interfaces/V2/IUniswapV2Exchange.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract ExampleFlashSwap is IUniswapV2Callee, UniswapV2Library {
    IUniswapV1Factory public factoryV1;
    IWETH public WETH;

    constructor(address _factoryV1) public {
        factoryV1 = IUniswapV1Factory(_factoryV1);
        // router address is identical across mainnet and testnets but differs between testing and deployed environments
        WETH = IWETH(IUniswapV2Router01(0x84e924C5E04438D2c1Df1A981f7E7104952e6de1).WETH());
    }

    // needs to accept ETH from any v1 exchange and WETH. ideally this could be enforced, as in the router,
    // but it's not possible because it requires a call to the v1 factory, which takes too much gas
    function() external payable {}

    // gets tokens/WETH via a V2 flash swap, swaps for the ETH/tokens on V1, repays V2, and keeps the rest!
    function uniswapV2Call(address sender, uint amount0, uint amount1, bytes calldata data) external {
        address[] memory path = new address[](2);
        uint amountToken;
        uint amountETH;
        { // scope for token{0,1}, avoids stack too deep errors
        address token0 = IUniswapV2Exchange(msg.sender).token0();
        address token1 = IUniswapV2Exchange(msg.sender).token1();
        assert(msg.sender == exchangeFor(token0, token1)); // ensure that msg.sender is actually a V2 exchange
        assert(amount0 == 0 || amount1 == 0); // this strategy is unidirectional
        path[0] = amount0 == 0 ? token0 : token1;
        path[1] = amount0 == 0 ? token1 : token0;
        amountToken = token0 == address(WETH) ? amount1 : amount0;
        amountETH = token0 == address(WETH) ? amount0 : amount1;
        }

        assert(path[0] == address(WETH) || path[1] == address(WETH)); // this strategy only works with a V2 WETH pair
        IERC20 token = IERC20(path[0] == address(WETH) ? path[1] : path[0]);
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(address(token))); // get V1 exchange

        if (amountToken > 0) {
            (uint minETH) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            token.approve(address(exchangeV1), amountToken);
            uint amountReceived = exchangeV1.tokenToEthSwapInput(amountToken, minETH, uint(-1));
            uint amountRequired = getAmountsIn(amountToken, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough ETH back to repay our flash loan
            WETH.deposit.value(amountRequired)();
            assert(WETH.transfer(msg.sender, amountRequired)); // return WETH to V2 exchange
            (bool success,) = sender.call.value(amountReceived - amountRequired)(new bytes(0)); // keep the rest! (ETH)
            assert(success);
        } else {
            (uint minTokens) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            WETH.withdraw(amountETH);
            uint amountReceived = exchangeV1.ethToTokenSwapInput.value(amountETH)(minTokens, uint(-1)); 
            uint amountRequired = getAmountsIn(amountETH, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough tokens back to repay our flash loan
            assert(token.transfer(msg.sender, amountRequired)); // return tokens to V2 exchange
            assert(token.transfer(sender, amountReceived - amountRequired)); // keep the rest! (tokens)
        }
    }
}