// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-0.8/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-0.8/utils/math/SafeMath.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../aerodrome/interfaces/IGauge.sol";
import "../aerodrome/interfaces/IVoter.sol";

import {IGauge as IEqualGauge} as "../equalizer/interfaces/IGauge.sol";
import {IVoter as IEqualVoter} "../equalizer/interfaces/IVoter.sol";

// Note that this pool has no minter key of bSHARE (rewards).
// Instead, the governance will call bSHARE distributeReward method and send reward to this pool at the beginning.
contract ShareRewardPool is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant TOTAL_REWARDS = 60000 ether;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    struct GaugeInfo {
        bool isGauge;   // If this is a gauge
        IGauge gauge;  // The gauge
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. bSHAREs to distribute in the pool.
        uint256 lastRewardTime; // Last time that bSHAREs distribution occured.
        uint256 accSharePerShare; // Accumulated bSHAREs per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
        GaugeInfo gaugeInfo; // Gauge info (does this pool have a gauge and where is it)
    }

    IERC20 public share;
    address public aero;
    address public scale;
    IVoter public voter;
    IEqualVoter public equalVoter
    address public bribesSafe;

    // Info of each pool.
    PoolInfo[] public poolInfo; 

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // The time when bSHARE mining starts.
    uint256 public poolStartTime;

    // The time when bSHARE mining ends.
    uint256 public poolEndTime;

    uint256 public sharePerSecond; // 60000 bSHARE / (370 days * 24h * 60min * 60s)
    uint256 public runningTime; // 370 days

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address _share, uint256 _poolStartTime, address _aero, address _scale, address _voter, address _equalVoter, address _bribesSafe) initializer public {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        totalAllocPoint = 0;
        sharePerSecond = 0.00187687 ether; // 60000 bSHARE / (370 days * 24h * 60min * 60s)
        runningTime = 370 days; // 370 days

        require(block.timestamp < _poolStartTime, "ShareRewardPool: Start time must be after current timestamp");
        if (_share != address(0)) share = IERC20(_share);
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;

        aero = _aero;
        scale = _scale;
        voter = IVoter(_voter);
        equalVoter = IEqualVoter(_equalVoter);
        bribesSafe = _bribesSafe;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "ShareRewardPool: Pool already exists");
        }
    }

    function isEqualizerGauge(address gauge) internal view returns (bool success) {
        (bool success, bytes memory _data) = gauge.staticcall(
            // Aerodrome gauges don't have a paused() function, so we use the selector of the paused() function of the Equalizer gauge interface
            abi.encodeWithSelector(IEqualGauge.paused.selector)
        );
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime
    ) public onlyRole(OPERATOR_ROLE) {
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted =
        (_lastRewardTime <= poolStartTime) ||
        (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({
            token : _token,
            allocPoint : _allocPoint,
            lastRewardTime : _lastRewardTime,
            accSharePerShare : 0,
            isStarted : _isStarted,
            gaugeInfo: GaugeInfo(false, IGauge(address(0)))
        }));
        enableGauge(poolInfo.length - 1);


        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's bSHARE allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyRole(OPERATOR_ROLE) {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(sharePerSecond);
            return poolEndTime.sub(_fromTime).mul(sharePerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(sharePerSecond);
            return _toTime.sub(_fromTime).mul(sharePerSecond);
        }
    }

    // View function to see pending bSHAREs on frontend.
    function pendingShare(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSharePerShare = pool.accSharePerShare;
        uint256 tokenSupply = pool.gaugeInfo.isGauge ? pool.gaugeInfo.gauge.balanceOf(address(this)) : pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _shareReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accSharePerShare = accSharePerShare.add(_shareReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accSharePerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
            updatePoolWithGaugeDeposit(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        updatePoolWithGaugeDeposit(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.gaugeInfo.isGauge ? pool.gaugeInfo.gauge.balanceOf(address(this)) : pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _shareReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accSharePerShare = pool.accSharePerShare.add(_shareReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
        if (isEqualizerGauge(pool.gaugeInfo.gauge)) {
            claimScaleRewards(_pid);
        } else {
            claimAeroRewards(_pid);
        }
    }

    // Deposit LP tokens to earn AERO/SCALE
    function updatePoolWithGaugeDeposit(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        address gauge = address(pool.gaugeInfo.gauge);
        uint256 balance = pool.token.balanceOf(address(this));
        // Do nothing if this pool doesn't have a gauge
        if (pool.gaugeInfo.isGauge) {
            // Do nothing if the LP token in the MC is empty
            if (balance > 0) {
                // Approve to the gauge
                if (pool.token.allowance(address(this), gauge) < balance ){
                    pool.token.approve(gauge, type(uint256).max);
                }
                // Deposit the LP in the gauge
                pool.gaugeInfo.gauge.deposit(balance, address(this));
            }
        }
    }

    // Claim AERO rewards to treasury
    function claimAeroRewards(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.gaugeInfo.isGauge) {
            // claim the aero
            pool.gaugeInfo.gauge.getReward(address(this));
            IERC20(aero).safeTransfer(bribesSafe, IERC20(aero).balanceOf(address(this)));   
        }
    }

    // Claim SCALE rewards to treasury
    function claimScaleRewards(uint256 _pic) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.gaugeInfo.isGauge) {
            // claim the scale
            pool.gaugeInfo.gauge.getReward(address(this));
            IERC20(scale).safeTransfer(bribesSafe, IERC20(scale).balanceOf(address(this)));   
        }
    }

    // Add a gauge to a pool
    function enableGauge(uint256 _pid) public onlyRole(OPERATOR_ROLE) {
        address aeroGauge = voter.gauges(address(poolInfo[_pid].token));
        address equalGauge = equalVoter.gauges(address(poolInfo[_pid].token));
        if (aeroGauge != address(0)) {
            poolInfo[_pid].gaugeInfo = GaugeInfo(true, IGauge(aeroGauge));
        }
        if (equalGauge != address(0)) {
            poolInfo[_pid].gaugeInfo = GaugeInfo(true, IGauge(equalGauge));
        }
    }

    function setBribesSafe(address _bribesSafe) public onlyRole(OPERATOR_ROLE) {
        bribesSafe = _bribesSafe;
    }

    // Withdraw LP from the gauge
    function withdrawFromGauge(uint256 _pid, uint256 _amount) internal {
        PoolInfo storage pool = poolInfo[_pid];
        // Do nothing if this pool doesn't have a gauge
        if (pool.gaugeInfo.isGauge) {
            // Withdraw from the gauge
            pool.gaugeInfo.gauge.withdraw(_amount);
        }
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, address _onBehalf, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_onBehalf];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accSharePerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeShareTransfer(_onBehalf, _pending);
                emit RewardPaid(_onBehalf, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        updatePoolWithGaugeDeposit(_pid);
        user.rewardDebt = user.amount.mul(pool.accSharePerShare).div(1e18);
        emit Deposit(_onBehalf, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "ShareRewardPool: Amount greater than balance");
        updatePool(_pid);
        updatePoolWithGaugeDeposit(_pid);
        uint256 _pending = user.amount.mul(pool.accSharePerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeShareTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            withdrawFromGauge(_pid, _amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSharePerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        withdrawFromGauge(_pid, _amount);
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe share transfer function, just in case if rounding error causes pool to not have enough bSHAREs.
    function safeShareTransfer(address _to, uint256 _amount) internal {
        uint256 _shareBal = share.balanceOf(address(this));
        if (_shareBal > 0) {
            if (_amount > _shareBal) {
                share.safeTransfer(_to, _shareBal);
            } else {
                share.safeTransfer(_to, _amount);
            }
        }
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyRole(OPERATOR_ROLE) {
        if (block.timestamp < poolEndTime + 90 days) {
            // do not allow to drain core token (bSHARE or lps) if less than 90 days after pool ends
            require(_token != share, "ShareRewardPool: Token cannot be bSHARE");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "ShareRewardPool: Token cannot be pool token");
            }
        }
        _token.safeTransfer(to, amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}
}
