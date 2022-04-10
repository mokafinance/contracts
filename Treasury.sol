// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IBoardroom.sol";

import "hardhat/console.sol";

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

contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours; 
    //uint256 public constant PERIOD = 0.02 hours; // TESTING

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // exclusions from total supply
    // removed from here and added in the initialize method
    // so we don't have them hardcoded here
    address[] public excludedFromTotalSupply;
        // address(0xB7e1E341b2CBCc7d1EdF4DC6E5e962aE5C621ca5), // MokaGenesisPool
        // address(0x04b79c851ed1A36549C6151189c79EC0eaBca745) // new MokaRewardPool

    // core components
    address public moka;
    address public bbond;
    address public bshare;

    address public boardroom;
    address public mokaOracle;

    address public mokaRewardPool;
    address public mokaGenesisRewardPool;

    // price
    uint256 public mokaPriceOne;
    uint256 public mokaPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of MOKA price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochMokaPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra MOKA during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 mokaAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 mokaAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event BoardroomFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition() {

        console.log("checkCondition called. Now: %s startTime: %s", now, startTime);

        require(now >= startTime, "Treasury: not started yet");
        _;
    }

    modifier checkEpoch() {

        console.log("check epoch called. Now: %s nextEpochPoint(): %s", now, nextEpochPoint());

        require(now >= nextEpochPoint(), "Treasury: not opened yet");
        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getMokaPrice() > mokaPriceCeiling) ? 0 : getMokaCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(moka).operator() == address(this) &&
                IBasisAsset(bbond).operator() == address(this) &&
                IBasisAsset(bshare).operator() == address(this) &&
                Operator(boardroom).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getMokaPrice() public view returns (uint256 mokaPrice) {
        try IOracle(mokaOracle).consult(moka, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult MOKA price from the oracle");
        }
    }

    function getMokaUpdatedPrice() public view returns (uint256 _mokaPrice) {
        try IOracle(mokaOracle).twap(moka, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult MOKA price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableMokaLeft() public view returns (uint256 _burnableMokaLeft) {
        uint256 _mokaPrice = getMokaPrice();
        if (_mokaPrice <= mokaPriceOne) {
            uint256 _mokaSupply = getMokaCirculatingSupply();
            uint256 _bondMaxSupply = _mokaSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableMoka = _maxMintableBond.mul(_mokaPrice).div(1e14);
                _burnableMokaLeft = Math.min(epochSupplyContractionLeft, _maxBurnableMoka);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _mokaPrice = getMokaPrice();
        if (_mokaPrice > mokaPriceCeiling) {
            uint256 _totalMoka = IERC20(moka).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalMoka.mul(1e14).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _mokaPrice = getMokaPrice();
        if (_mokaPrice <= mokaPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = mokaPriceOne;
            } else {
                uint256 _bondAmount = mokaPriceOne.mul(1e18).div(_mokaPrice); // to burn 1 MOKA
                uint256 _discountAmount = _bondAmount.sub(mokaPriceOne).mul(discountPercent).div(10000);
                _rate = mokaPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _mokaPrice = getMokaPrice();
        if (_mokaPrice > mokaPriceCeiling) {
            uint256 _mokaPricePremiumThreshold = mokaPriceOne.mul(premiumThreshold).div(100);
            if (_mokaPrice >= _mokaPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _mokaPrice.sub(mokaPriceOne).mul(premiumPercent).div(10000);
                _rate = mokaPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = mokaPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _moka,
        address _bbond,
        address _bshare,
        address _mokaOracle,
        address _boardroom,
        address _mokaRewardPool,
        address _mokaGenesisRewardPool,
        uint256 _startTime
    ) public notInitialized {
        moka = _moka;
        bbond = _bbond;
        bshare = _bshare;
        mokaOracle = _mokaOracle;
        boardroom = _boardroom;
        startTime = _startTime;

        mokaRewardPool = _mokaRewardPool;
        mokaGenesisRewardPool = _mokaGenesisRewardPool;

        mokaPriceOne = 10**14; // This is to allow a PEG of 10,000 MOKA per BTC
        mokaPriceCeiling = mokaPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500000 ether, 1000000 ether, 1500000 ether, 2000000 ether, 5000000 ether, 10000000 ether, 20000000 ether, 50000000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for boardroom

        maxSupplyContractionPercent = 300; // Up to 3.0% supply for contraction (to burn MOKA and mint bMOKA)
        maxDebtRatioPercent = 4500; // Up to 45% supply of bMOKA to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 28;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to its balance
        seigniorageSaved = IERC20(moka).balanceOf(address(this));

        // set pool exclusions as we don't want these hardcoded
        excludedFromTotalSupply.push(mokaRewardPool);
        excludedFromTotalSupply.push(mokaGenesisRewardPool);

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setBoardroom(address _boardroom) external onlyOperator {
        boardroom = _boardroom;
    }

    function setMokaOracle(address _mokaOracle) external onlyOperator {
        mokaOracle = _mokaOracle;
    }

    function setMokaRewardPool(address _mokaRewardPool) external onlyOperator {
        mokaRewardPool = _mokaRewardPool;
    }

    function setMokaGenesisRewardPool(address _mokaGenesisRewardPool) external onlyOperator {
        mokaGenesisRewardPool = _mokaGenesisRewardPool;
    }

    function setMokaPriceCeiling(uint256 _mokaPriceCeiling) external onlyOperator {
        require(_mokaPriceCeiling >= mokaPriceOne && _mokaPriceCeiling <= mokaPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        mokaPriceCeiling = _mokaPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= mokaPriceCeiling, "_premiumThreshold exceeds mokaPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateMokaPrice() internal {
        try IOracle(mokaOracle).update() {} catch {}
    }

    function getMokaCirculatingSupply() public view returns (uint256) {
        IERC20 mokaErc20 = IERC20(moka);
        uint256 totalSupply = mokaErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(mokaErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _mokaAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_mokaAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 mokaPrice = getMokaPrice();
        require(mokaPrice == targetPrice, "Treasury: MOKA price moved");
        require(
            mokaPrice < mokaPriceOne, // price < $1
            "Treasury: mokaPrice not eligible for bond purchase"
        );

        require(_mokaAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _mokaAmount.mul(_rate).div(1e14);
        uint256 mokaSupply = getMokaCirculatingSupply();
        uint256 newBondSupply = IERC20(bbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= mokaSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(moka).burnFrom(msg.sender, _mokaAmount);
        IBasisAsset(bbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_mokaAmount);
        _updateMokaPrice();

        emit BoughtBonds(msg.sender, _mokaAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 mokaPrice = getMokaPrice();
        require(mokaPrice == targetPrice, "Treasury: MOKA price moved");
        require(
            mokaPrice > mokaPriceCeiling, // price > $1.01
            "Treasury: mokaPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _mokaAmount = _bondAmount.mul(_rate).div(1e14);
        require(IERC20(moka).balanceOf(address(this)) >= _mokaAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _mokaAmount));

        IBasisAsset(bbond).burnFrom(msg.sender, _bondAmount);
        IERC20(moka).safeTransfer(msg.sender, _mokaAmount);

        _updateMokaPrice();

        emit RedeemedBonds(msg.sender, _mokaAmount, _bondAmount);
    }

    function _sendToBoardroom(uint256 _amount) internal {
        IBasisAsset(moka).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(moka).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(moka).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(moka).safeApprove(boardroom, 0);
        IERC20(moka).safeApprove(boardroom, _amount);
        IBoardroom(boardroom).allocateSeigniorage(_amount);
        emit BoardroomFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _mokaSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_mokaSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateMokaPrice();
        previousEpochMokaPrice = getMokaPrice();
        uint256 mokaSupply = getMokaCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToBoardroom(mokaSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochMokaPrice > mokaPriceCeiling) {
                // Expansion ($MOKA Price > 1 $ETH): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bbond).totalSupply();
                uint256 _percentage = previousEpochMokaPrice.sub(mokaPriceOne);
                uint256 _savedForBond;
                uint256 _savedForBoardroom;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(mokaSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForBoardroom = mokaSupply.mul(_percentage).div(1e14);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = mokaSupply.mul(_percentage).div(1e14);
                    _savedForBoardroom = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForBoardroom);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForBoardroom > 0) {
                    _sendToBoardroom(_savedForBoardroom);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(moka).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(moka), "moka");
        require(address(_token) != address(bbond), "bond");
        require(address(_token) != address(bshare), "share");
        _token.safeTransfer(_to, _amount);
    }

    function boardroomSetOperator(address _operator) external onlyOperator {
        IBoardroom(boardroom).setOperator(_operator);
    }

    function boardroomSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IBoardroom(boardroom).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function boardroomAllocateSeigniorage(uint256 amount) external onlyOperator {
        IBoardroom(boardroom).allocateSeigniorage(amount);
    }

    function boardroomGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IBoardroom(boardroom).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
