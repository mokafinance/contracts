// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IERC20.sol";

/*

 /$$      /$$           /$$                      /$$$$$$  /$$                                                  
| $$$    /$$$          | $$                     /$$__  $$|__/                                                  
| $$$$  /$$$$  /$$$$$$ | $$   /$$  /$$$$$$     | $$  \__/ /$$ /$$$$$$$   /$$$$$$  /$$$$$$$   /$$$$$$$  /$$$$$$ 
| $$ $$/$$ $$ /$$__  $$| $$  /$$/ |____  $$    | $$$$    | $$| $$__  $$ |____  $$| $$__  $$ /$$_____/ /$$__  $$
| $$  $$$| $$| $$  \ $$| $$$$$$/   /$$$$$$$    | $$_/    | $$| $$  \ $$  /$$$$$$$| $$  \ $$| $$      | $$$$$$$$
| $$\  $ | $$| $$  | $$| $$_  $$  /$$__  $$    | $$      | $$| $$  | $$ /$$__  $$| $$  | $$| $$      | $$_____/
| $$ \/  | $$|  $$$$$$/| $$ \  $$|  $$$$$$$ /$$| $$      | $$| $$  | $$|  $$$$$$$| $$  | $$|  $$$$$$$|  $$$$$$$
|__/     |__/ \______/ |__/  \__/ \_______/|__/|__/      |__/|__/  |__/ \_______/|__/  |__/ \_______/ \_______/

*/

contract TaxOfficeV2 is Operator {
    using SafeMath for uint256;

    address public moka;
    address public uniRouter;
    
    constructor(address _mokaAddress, address _uniRouter) public {
        moka = _mokaAddress;
        uniRouter = _uniRouter;
    }

    mapping(address => bool) public taxExclusionEnabled;

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(moka).setTaxTiersTwap(_index, _value);
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(moka).setTaxTiersRate(_index, _value);
    }

    function enableAutoCalculateTax() public onlyOperator {
        ITaxable(moka).enableAutoCalculateTax();
    }

    function disableAutoCalculateTax() public onlyOperator {
        ITaxable(moka).disableAutoCalculateTax();
    }

    function setTaxRate(uint256 _taxRate) public onlyOperator {
        ITaxable(moka).setTaxRate(_taxRate);
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyOperator {
        ITaxable(moka).setBurnThreshold(_burnThreshold);
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        ITaxable(moka).setTaxCollectorAddress(_taxCollectorAddress);
    }

    function excludeAddressFromTax(address _address) external onlyOperator returns (bool) {
        return _excludeAddressFromTax(_address);
    }

    function _excludeAddressFromTax(address _address) private returns (bool) {
        if (!ITaxable(moka).isAddressExcluded(_address)) {
            return ITaxable(moka).excludeAddress(_address);
        }
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return _includeAddressInTax(_address);
    }

    function _includeAddressInTax(address _address) private returns (bool) {
        if (ITaxable(moka).isAddressExcluded(_address)) {
            return ITaxable(moka).includeAddress(_address);
        }
    }

    function taxRate() external returns (uint256) {
        return ITaxable(moka).taxRate();
    }

    function addLiquidityTaxFree(
        address token,
        uint256 amtMoka,
        uint256 amtToken,
        uint256 amtMokaMin,
        uint256 amtTokenMin
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtMoka != 0 && amtToken != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(moka).transferFrom(msg.sender, address(this), amtMoka);
        IERC20(token).transferFrom(msg.sender, address(this), amtToken);
        _approveTokenIfNeeded(moka, uniRouter);
        _approveTokenIfNeeded(token, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtMoka;
        uint256 resultAmtToken;
        uint256 liquidity;
        (resultAmtMoka, resultAmtToken, liquidity) = IUniswapV2Router(uniRouter).addLiquidity(
            moka,
            token,
            amtMoka,
            amtToken,
            amtMokaMin,
            amtTokenMin,
            msg.sender,
            block.timestamp
        );

        if (amtMoka.sub(resultAmtMoka) > 0) {
            IERC20(moka).transfer(msg.sender, amtMoka.sub(resultAmtMoka));
        }
        if (amtToken.sub(resultAmtToken) > 0) {
            IERC20(token).transfer(msg.sender, amtToken.sub(resultAmtToken));
        }
        return (resultAmtMoka, resultAmtToken, liquidity);
    }

    function addLiquidityETHTaxFree(
        uint256 amtMoka,
        uint256 amtMokaMin,
        uint256 amtEthMin
    )
        external
        payable
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtMoka != 0 && msg.value != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(moka).transferFrom(msg.sender, address(this), amtMoka);
        _approveTokenIfNeeded(moka, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtMoka;
        uint256 resultAmtEth;
        uint256 liquidity;
        (resultAmtMoka, resultAmtEth, liquidity) = IUniswapV2Router(uniRouter).addLiquidityETH{value: msg.value}(
            moka,
            amtMoka,
            amtMokaMin,
            amtEthMin,
            msg.sender,
            block.timestamp
        );

        if (amtMoka.sub(resultAmtMoka) > 0) {
            IERC20(moka).transfer(msg.sender, amtMoka.sub(resultAmtMoka));
        }
        return (resultAmtMoka, resultAmtEth, liquidity);
    }

    function setTaxableMokaOracle(address _mokaOracle) external onlyOperator {
        ITaxable(moka).setMokaOracle(_mokaOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(moka).setTaxOffice(_newTaxOffice);
    }

    function taxFreeTransferFrom(
        address _sender,
        address _recipient,
        uint256 _amt
    ) external {
        require(taxExclusionEnabled[msg.sender], "Address not approved for tax free transfers");
        _excludeAddressFromTax(_sender);
        IERC20(moka).transferFrom(_sender, _recipient, _amt);
        _includeAddressInTax(_sender);
    }

    function setTaxExclusionForAddress(address _address, bool _excluded) external onlyOperator {
        taxExclusionEnabled[_address] = _excluded;
    }

    function _approveTokenIfNeeded(address _token, address _router) private {
        if (IERC20(_token).allowance(address(this), _router) == 0) {
            IERC20(_token).approve(_router, type(uint256).max);
        }
    }
}
