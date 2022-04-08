// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

contract TaxOracle is Ownable {
    using SafeMath for uint256;

    IERC20 public moka;
    IERC20 public btcb;
    address public pair;

    constructor(
        address _moka,
        address _btcb,
        address _pair
    ) public {
        require(_moka != address(0), "moka address cannot be 0");
        require(_btcb != address(0), "btcb address cannot be 0");
        require(_pair != address(0), "pair address cannot be 0");
        moka = IERC20(_moka);
        btcb = IERC20(_btcb);
        pair = _pair;
    }

    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        require(_token == address(moka), "token needs to be moka");
        uint256 mokaBalance = moka.balanceOf(pair);
        uint256 btcbBalance = btcb.balanceOf(pair);
        return uint144(mokaBalance.mul(_amountIn).div(btcbBalance));
    }

    function getMokaBalance() external view returns (uint256) {
	   return moka.balanceOf(pair);
    }

    function getBtcbBalance() external view returns (uint256) {
	   return btcb.balanceOf(pair);
    }

    function getPrice() external view returns (uint256) {
        uint256 mokaBalance = moka.balanceOf(pair);
        uint256 btcbBalance = btcb.balanceOf(pair);
        return mokaBalance.mul(1e18).div(btcbBalance);
    }


    function setMoka(address _moka) external onlyOwner {
        require(_moka != address(0), "moka address cannot be 0");
        moka = IERC20(_moka);
    }

    function setBtcb(address _btcb) external onlyOwner {
        require(_btcb != address(0), "btcb address cannot be 0");
        btcb = IERC20(_btcb);
    }

    function setPair(address _pair) external onlyOwner {
        require(_pair != address(0), "pair address cannot be 0");
        pair = _pair;
    }

}