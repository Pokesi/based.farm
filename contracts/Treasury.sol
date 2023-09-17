// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-0.8/utils/math/Math.sol";
import "@openzeppelin/contracts-0.8/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./utils/ContractGuardUpgradeable.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IAccessControl.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IForge.sol";

contract Treasury is Initializable, ContractGuardUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // flags
    bool public started;
    bool public bondsStarted;

    // epoch
    uint256 public startTime;
    uint256 public epoch;
    uint256 public epochSupplyContractionLeft;

    // exclusions from total supply
    address[] public excludedFromTotalSupply;

    // core components
    address public based;
    address public bond;
    address public share;

    address public forge;
    address public oracle;

    // price
    uint256 public basedPriceOne;
    uint256 public basedPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 12 first epochs with 5% expansion regardless of BASED price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochBasedPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra BASED during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Started(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 basedAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 basedAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event ForgeFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier checkCondition {
        require(block.timestamp >= startTime, "Treasury: Not started yet");

        _;
    }

    modifier checkEpoch {
        require(block.timestamp >= nextEpochPoint(), "Treasury: Not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getBasedPrice() > basedPriceCeiling) ? 0 : getBasedCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IAccessControl(based).hasRole(OPERATOR_ROLE, address(this)) &&
            IAccessControl(bond).hasRole(OPERATOR_ROLE, address(this)) &&
            IAccessControl(share).hasRole(OPERATOR_ROLE, address(this)) &&
            IAccessControl(forge).hasRole(OPERATOR_ROLE, address(this)),
            "Treasury: Need more permission"
        );

        _;
    }

    modifier notStarted {
        require(!started, "Treasury: Already started");

        _;
    }

    modifier hasStarted {
        require(bondsStarted, "Treasury: Bonds not started");

        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() initializer public {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        started = false;
        bondsStarted = false;
        epoch = 0;
        epochSupplyContractionLeft = 0;

        basedPriceOne = 10**18;
        basedPriceCeiling = basedPriceOne.mul(10003).div(10000);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500 ether, 1000 ether, 1500 ether, 2000 ether, 5000 ether, 10000 ether, 20000 ether, 50000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for forge
        maxSupplyContractionPercent = 300; // Up to 3.0% supply for contraction (to burn BASED and mint bBOND)
        maxDebtRatioPercent = 3500; // Up to 35% supply of bBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 12 epochs with 5% expansion
        bootstrapEpochs = 12;
        bootstrapSupplyExpansionPercent = 500;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isStarted() public view returns (bool) {
        return started;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getBasedPrice() public view returns (uint256 basedPrice) {
        try IOracle(oracle).consult(based, 1e18) returns (uint256 price) {
            return uint256(price);
        } catch {
            revert("Treasury: Failed to consult BASED price from the oracle");
        }
    }

    function getBasedUpdatedPrice() public view returns (uint256 _basedPrice) {
        try IOracle(oracle).twap(based, 1e18) returns (uint256 price) {
            return uint256(price);
        } catch {
            revert("Treasury: Failed to consult BASED price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableBasedLeft() public view returns (uint256 _burnableBasedLeft) {
        uint256 _basedPrice = getBasedPrice();
        if (_basedPrice <= basedPriceOne) {
            uint256 _basedSupply = getBasedCirculatingSupply();
            uint256 _bondMaxSupply = _basedSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableBased = _maxMintableBond.mul(_basedPrice).div(1e18);
                _burnableBasedLeft = Math.min(epochSupplyContractionLeft, _maxBurnableBased);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _basedPrice = getBasedPrice();
        if (_basedPrice > basedPriceCeiling) {
            uint256 _totalBased = IERC20(based).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalBased.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _basedPrice = getBasedPrice();
        if (_basedPrice <= basedPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = basedPriceOne;
            } else {
                uint256 _bondAmount = basedPriceOne.mul(1e18).div(_basedPrice); // to burn 1 BASED
                uint256 _discountAmount = _bondAmount.sub(basedPriceOne).mul(discountPercent).div(10000);
                _rate = basedPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _basedPrice = getBasedPrice();
        if (_basedPrice > basedPriceCeiling) {
            uint256 _basedPricePremiumThreshold = basedPriceOne.mul(premiumThreshold).div(100);
            if (_basedPrice >= _basedPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _basedPrice.sub(basedPriceOne).mul(premiumPercent).div(10000);
                _rate = basedPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = basedPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function start(
        address _based,
        address _bond,
        address _share,
        address _oracle,
        address _forge,
        address _genesisPool,
        address _basedRewardPool,
        uint256 _startTime
    ) public notStarted onlyRole(OPERATOR_ROLE) {
        based = _based;
        bond = _bond;
        share = _share;
        oracle = _oracle;
        forge = _forge;
        startTime = _startTime;

        // exclude contracts from total supply
        excludedFromTotalSupply.push(_genesisPool);
        excludedFromTotalSupply.push(_basedRewardPool);

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(based).balanceOf(address(this));

        started = true;
        emit Started(msg.sender, block.number);
    }

    function startBonds() public onlyRole(OPERATOR_ROLE) {
        bondsStarted = true;
    }

    function setForge(address _forge) external onlyRole(OPERATOR_ROLE) {
        forge = _forge;
    }

    function setOracle(address _oracle) external onlyRole(OPERATOR_ROLE) {
        oracle = _oracle;
    }

    function setBasedPriceCeiling(uint256 _basedPriceCeiling) external onlyRole(OPERATOR_ROLE) {
        require(_basedPriceCeiling >= basedPriceOne && _basedPriceCeiling <= basedPriceOne.mul(120).div(100), "Treasury: Out of range"); // [$1.0, $1.2]
        basedPriceCeiling = _basedPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyRole(OPERATOR_ROLE) {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "Treasury: _maxSupplyExpansionPercent out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyRole(OPERATOR_ROLE) returns (bool) {
        require(_index >= 0, "Treasury: Index has to be higher than 0");
        require(_index < 9, "Treasury: Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyRole(OPERATOR_ROLE) returns (bool) {
        require(_index >= 0, "Treasury: Index has to be higher than 0");
        require(_index < 9, "Treasury: Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "Treasury: _value out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyRole(OPERATOR_ROLE) {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "Treasury: Out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyRole(OPERATOR_ROLE) {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "Treasury: Out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyRole(OPERATOR_ROLE) {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "Treasury: Out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyRole(OPERATOR_ROLE) {
        require(_bootstrapEpochs <= 120, "Treasury: _bootstrapEpochs out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "Treasury: _bootstrapSupplyExpansionPercent out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyRole(OPERATOR_ROLE) {
        require(_daoFund != address(0), "Treasury: DAO fund must be a non-zero address");
        require(_daoFundSharedPercent <= 3000, "Treasury: Out of range"); // <= 30%
        require(_devFund != address(0), "Treasury: Dev fund must be a non-zero address");
        require(_devFundSharedPercent <= 1000, "Treasury: Out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyRole(OPERATOR_ROLE) {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyRole(OPERATOR_ROLE) {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyRole(OPERATOR_ROLE) {
        require(_discountPercent <= 20000, "Treasury: _discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyRole(OPERATOR_ROLE) {
        require(_premiumThreshold >= basedPriceCeiling, "Treasury: _premiumThreshold exceeds basedPriceCeiling");
        require(_premiumThreshold <= 150, "Treasury: _premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyRole(OPERATOR_ROLE) {
        require(_premiumPercent <= 20000, "Treasury: _premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyRole(OPERATOR_ROLE) {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "Treasury: _mintingFactorForPayingDebt out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateBasedPrice() internal {
        try IOracle(oracle).update() {} catch {}
    }

    function getBasedCirculatingSupply() public view returns (uint256) {
        IERC20 basedErc20 = IERC20(based);
        uint256 totalSupply = basedErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(basedErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _basedAmount, uint256 targetPrice) external hasStarted onlyOneBlock checkCondition checkOperator {
        require(_basedAmount > 0, "Treasury: Cannot purchase bonds with zero amount");

        uint256 basedPrice = getBasedPrice();
        require(basedPrice == targetPrice, "Treasury: BASED price moved");
        require(
            basedPrice < basedPriceOne, // price < $1
            "Treasury: basedPrice not eligible for bond purchase"
        );

        require(_basedAmount <= epochSupplyContractionLeft, "Treasury: Not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: Invalid bond rate");

        uint256 _bondAmount = _basedAmount.mul(_rate).div(1e18);
        uint256 basedSupply = getBasedCirculatingSupply();
        uint256 newBondSupply = IERC20(bond).totalSupply().add(_bondAmount);
        require(newBondSupply <= basedSupply.mul(maxDebtRatioPercent).div(10000), "Treasury: Over max debt ratio");

        IBasisAsset(based).burnFrom(msg.sender, _basedAmount);
        IBasisAsset(bond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_basedAmount);
        _updateBasedPrice();

        emit BoughtBonds(msg.sender, _basedAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external hasStarted onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: Cannot redeem bonds with zero amount");

        uint256 basedPrice = getBasedPrice();
        require(basedPrice == targetPrice, "Treasury: BASED price moved");
        require(
            basedPrice > basedPriceCeiling, // price > $1.01
            "Treasury: basedPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: Invalid bond rate");

        uint256 _basedAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(based).balanceOf(address(this)) >= _basedAmount, "Treasury: Treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _basedAmount));

        IBasisAsset(bond).burnFrom(msg.sender, _bondAmount);
        IERC20(based).safeTransfer(msg.sender, _basedAmount);

        _updateBasedPrice();

        emit RedeemedBonds(msg.sender, _basedAmount, _bondAmount);
    }

    function _sendToForge(uint256 _amount) internal {
        IBasisAsset(based).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(based).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(block.timestamp, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(based).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(block.timestamp, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(based).safeApprove(forge, 0);
        IERC20(based).safeApprove(forge, _amount);
        IForge(forge).allocateSeigniorage(_amount);
        emit ForgeFunded(block.timestamp, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _basedSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_basedSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateBasedPrice();
        previousEpochBasedPrice = getBasedPrice();
        uint256 basedSupply = getBasedCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToForge(basedSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochBasedPrice > basedPriceCeiling) {
                // Expansion ($BASED Price > 1 $ETH): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bond).totalSupply();
                uint256 _percentage = previousEpochBasedPrice.sub(basedPriceOne);
                uint256 _savedForBond;
                uint256 _savedForForge;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(basedSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForForge = basedSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = basedSupply.mul(_percentage).div(1e18);
                    _savedForForge = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForForge);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForForge > 0) {
                    _sendToForge(_savedForForge);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(based).mint(address(this), _savedForBond);
                    emit TreasuryFunded(block.timestamp, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyRole(OPERATOR_ROLE) {
        // do not allow to drain core tokens
        require(address(_token) != address(based), "Treasury: Token cannot be BASED");
        require(address(_token) != address(bond), "Treasury: Token cannot be bBOND");
        require(address(_token) != address(share), "Treasury: Token cannot be bSHARE");
        _token.safeTransfer(_to, _amount);
    }

    function forgeSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyRole(OPERATOR_ROLE) {
        IForge(forge).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function forgeAllocateSeigniorage(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        IForge(forge).allocateSeigniorage(amount);
    }

    function forgeGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyRole(OPERATOR_ROLE) {
        IForge(forge).governanceRecoverUnsupported(_token, _amount, _to);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}
}
