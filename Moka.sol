// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./lib/SafeMath8.sol";
import "./owner/Operator.sol";
import "./interfaces/IOracle.sol";

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

contract Moka is ERC20Burnable, Operator {
    using SafeMath8 for uint8;
    using SafeMath for uint256;

    // Initial distribution for the first 24h genesis pools
    uint256 public constant INITIAL_GENESIS_POOL_DISTRIBUTION = 11000 ether;
    // Initial distribution for the day 2-5 MOKA-WETH LP -> MOKA pool
    uint256 public constant INITIAL_MOKA_POOL_DISTRIBUTION = 140000 ether;
    // Distribution for airdrops wallet
    uint256 public constant INITIAL_AIRDROP_WALLET_DISTRIBUTION = 9000 ether;

    // Have the rewards been distributed to the pools
    bool public rewardPoolDistributed = false;

    /* ================= Taxation =============== */
    // Address of the Oracle
    address public mokaOracle;
    // Address of the Tax Office
    address public taxOffice;

    // Current tax rate
    uint256 public taxRate;
    // Price threshold below which taxes will get burned
    uint256 public burnThreshold = 1.10e18;
    // Address of the tax collector wallet
    address public taxCollectorAddress;

    // Should the taxes be calculated using the tax tiers
    bool public autoCalculateTax;

    // Tax Tiers
    uint256[] public taxTiersTwaps = [0, 5e17, 6e17, 7e17, 8e17, 9e17, 9.5e17, 1e18, 1.05e18, 1.10e18, 1.20e18, 1.30e18, 1.40e18, 1.50e18];
    uint256[] public taxTiersRates = [2000, 1900, 1800, 1700, 1600, 1500, 1500, 1500, 1500, 1400, 900, 400, 200, 100];

    // Sender addresses excluded from Tax
    mapping(address => bool) public excludedAddresses;

    mapping (address => bool) public automatedMarketMakerPairs;

    // Sells have fees of 4.8 and 12 (16.8 total) (4 * 1.2 and 10 * 1.2)
    uint256 public immutable sellFeeIncreaseFactor = 100; // @note Disabled sell fee increase factor

    // Track last sell to reduce sell penalty over time by 10% per week the holder sells *no* tokens
    mapping (address => uint256) public lastSellDate;

    event TaxOfficeTransferred(address oldAddress, address newAddress);

    modifier onlyTaxOffice() {
        require(taxOffice == msg.sender, "Caller is not the tax office");
        _;
    }

    modifier onlyOperatorOrTaxOffice() {
        require(isOperator() || taxOffice == msg.sender, "Caller is not the operator or the tax office");
        _;
    }

    /**
     * @notice Constructs the MOKA ERC-20 contract.
     */
    constructor(uint256 _taxRate, address _taxCollectorAddress) public ERC20("MOKA Finance", "MOKA") {
        
        require(_taxRate < 10000, "tax equal or bigger to 100%");
        require(_taxCollectorAddress != address(0), "tax collector address must be non-zero address");

        excludeAddress(address(this));

        // Mints 10 MOKA to contract creator for initial pool setup
        _mint(msg.sender, 10 ether);
        taxRate = _taxRate;
        taxCollectorAddress = _taxCollectorAddress;
    }

    /* ============= Taxation ============= */

    function getTaxTiersTwapsCount() public view returns (uint256 count) {
        return taxTiersTwaps.length;
    }

    function getTaxTiersRatesCount() public view returns (uint256 count) {
        return taxTiersRates.length;
    }

    function isAddressExcluded(address _address) public view returns (bool) {
        return excludedAddresses[_address];
    }

    function getHolderSellFactor(address holder) public view returns (uint256) {

        // Get time since last sell measured in 2 week increments
        uint256 timeSinceLastSale = (block.timestamp.sub(lastSellDate[holder])).div(2 weeks);

        // Protection in case someone tries to use a contract to facilitate buys/sells
        if (lastSellDate[holder] == 0) {
            return sellFeeIncreaseFactor;
        }

        // Cap the sell factor cooldown to 26 weeks 
        if (timeSinceLastSale >= 12) {
            return 100; // 
        }

        // Return the fee factor minus the number of weeks since sale * 10.  SellFeeIncreaseFactor is immutable at 120 so the most this can subtract is 11*10 = 120 - 110 = 10%
        return sellFeeIncreaseFactor-(timeSinceLastSale.mul(10));
    }

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyTaxOffice returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < getTaxTiersTwapsCount(), "Index has to lower than count of tax tiers");
        if (_index > 0) {
            require(_value > taxTiersTwaps[_index - 1]);
        }
        if (_index < getTaxTiersTwapsCount().sub(1)) {
            require(_value < taxTiersTwaps[_index + 1]);
        }
        taxTiersTwaps[_index] = _value;
        return true;
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyTaxOffice returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < getTaxTiersRatesCount(), "Index has to lower than count of tax tiers");
        taxTiersRates[_index] = _value;
        return true;
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyTaxOffice returns (bool) {
        burnThreshold = _burnThreshold;
    }

    function _getMokaPrice() internal view returns (uint256 _mokaPrice) {
        try IOracle(mokaOracle).consult(address(this), 1e18) returns (uint144 _price) {
            return uint256(_price);
        } catch {
            revert("Moka: failed to fetch MOKA price from Oracle");
        }
    }

    function _updateTaxRate(uint256 _mokaPrice) internal returns (uint256) {
        if (autoCalculateTax) {
            for (uint8 tierId = uint8(getTaxTiersTwapsCount()).sub(1); tierId >= 0; --tierId) {
                if (_mokaPrice >= taxTiersTwaps[tierId]) {
                    require(taxTiersRates[tierId] < 10000, "tax equal or bigger to 100%");
                    taxRate = taxTiersRates[tierId];
                    return taxTiersRates[tierId];
                }
            }
        }
    }

    function enableAutoCalculateTax() public onlyTaxOffice {
        autoCalculateTax = true;
    }

    function disableAutoCalculateTax() public onlyTaxOffice {
        autoCalculateTax = false;
    }

    function addAutomatedMarketMakerPair(address pair) public onlyOperator {
        automatedMarketMakerPairs[pair] = true;
    }

    function removeAutomatedMarketMakerPair(address pair) public onlyOperator {
        automatedMarketMakerPairs[pair] = false;
    }

    function setMokaOracle(address _mokaOracle) public onlyOperatorOrTaxOffice {
        require(_mokaOracle != address(0), "oracle address cannot be 0 address");
        mokaOracle = _mokaOracle;
    }

    function setTaxOffice(address _taxOffice) public onlyOperatorOrTaxOffice {
        require(_taxOffice != address(0), "tax office address cannot be 0 address");
        emit TaxOfficeTransferred(taxOffice, _taxOffice);
        taxOffice = _taxOffice;
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyTaxOffice {
        require(_taxCollectorAddress != address(0), "tax collector address must be non-zero address");
        taxCollectorAddress = _taxCollectorAddress;
    }

    function setTaxRate(uint256 _taxRate) public onlyTaxOffice {
        require(!autoCalculateTax, "auto calculate tax cannot be enabled");
        require(_taxRate < 10000, "tax equal or bigger to 100%");
        taxRate = _taxRate;
    }

    function excludeAddress(address _address) public onlyOperatorOrTaxOffice returns (bool) {
        require(!excludedAddresses[_address], "address can't be excluded");
        excludedAddresses[_address] = true;
        return true;
    }

    function includeAddress(address _address) public onlyOperatorOrTaxOffice returns (bool) {
        require(excludedAddresses[_address], "address can't be included");
        excludedAddresses[_address] = false;
        return true;
    }

    /**
     * @notice Operator mints MOKA to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of MOKA to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }

    function transfer(
        address recipient, 
        uint256 amount) public override returns (bool) {
        _transferInternal(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transferInternal(sender, recipient, amount);
        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function _transferInternal(
        address sender,
        address recipient,
        uint256 amount
    ) private {
        uint256 currentTaxRate = 0;
        bool burnTax = false;

        if (autoCalculateTax) {
            uint256 currentMokaPrice = _getMokaPrice();
            currentTaxRate = _updateTaxRate(currentMokaPrice);
            if (currentMokaPrice < burnThreshold) {
                burnTax = true;
            }
        }

        // Set the last sell date to first purchase date for new wallet
        if (!excludedAddresses[recipient] && lastSellDate[recipient] == 0) {
                lastSellDate[recipient] = block.timestamp;
        }

        // Prevent gaming the tax system
        if (automatedMarketMakerPairs[sender] && !excludedAddresses[recipient]) {
            if (lastSellDate[recipient] >= block.timestamp) {
                lastSellDate[recipient] = lastSellDate[recipient].add(block.timestamp.sub(lastSellDate[recipient]).div(3));
            }
        }

        if (currentTaxRate == 0 || excludedAddresses[sender]) {
            _transfer(sender, recipient, amount);
        } else {
            _transferWithTax(sender, recipient, amount, burnTax);
        }
    }

    function _transferWithTax(
        address sender,
        address recipient,
        uint256 amount,
        bool burnTax
    ) internal returns (bool) {
        uint256 taxAmount = amount.mul(taxRate).div(10000);
        taxAmount = taxAmount.mul(getHolderSellFactor(sender)).div(100);
        uint256 amountAfterTax = amount.sub(taxAmount);
        lastSellDate[sender] = block.timestamp; // update last sale date on sell

        if (burnTax) {
            // Burn tax
            super.burnFrom(sender, taxAmount);
        } else {
            // Transfer tax to tax collector
            _transfer(sender, taxCollectorAddress, taxAmount);
        }

        // Transfer amount after tax to recipient
        _transfer(sender, recipient, amountAfterTax);

        return true;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(
        address _genesisPool,
        address _mokaPool,
        address _airdropWallet
    ) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_genesisPool != address(0), "!_genesisPool");
        require(_mokaPool != address(0), "!_mokaPool");
        require(_airdropWallet != address(0), "!_airdropWallet");
        rewardPoolDistributed = true;
        _mint(_genesisPool, INITIAL_GENESIS_POOL_DISTRIBUTION);
        _mint(_mokaPool, INITIAL_MOKA_POOL_DISTRIBUTION);
        _mint(_airdropWallet, INITIAL_AIRDROP_WALLET_DISTRIBUTION);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
