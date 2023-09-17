// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-0.8/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./utils/ContractGuardUpgradeable.sol";
import "./utils/ShareWrapperUpgradeable.sol";
import "./interfaces/ITreasury.sol";

contract Forge is Initializable, ShareWrapperUpgradeable, ContractGuardUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    struct BlacksmithSeat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
        uint256 epochTimerStart;
    }

    struct ForgeSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    bool public started;

    IERC20 public based;
    ITreasury public treasury;

    mapping(address => BlacksmithSeat) public blacksmiths;
    ForgeSnapshot[] public forgeHistory;

    uint256 public withdrawLockupEpochs;
    uint256 public rewardLockupEpochs;

    event Started(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(address indexed user, uint256 reward);

    modifier blacksmithExists {
        require(balanceOf(msg.sender) > 0, "Forge: Blacksmith does not exist");
        _;
    }

    modifier updateReward(address blacksmith) {
        if (blacksmith != address(0)) {
            BlacksmithSeat memory seat = blacksmiths[blacksmith];
            seat.rewardEarned = earned(blacksmith);
            seat.lastSnapshotIndex = latestSnapshotIndex();
            blacksmiths[blacksmith] = seat;
        }
        _;
    }

    modifier notStarted {
        require(!started, "Forge: Already started");
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
        withdrawLockupEpochs = 6; // Lock for 6 epochs (36h) before release withdraw
        rewardLockupEpochs = 3; // Lock for 3 epochs (18h) before release claimReward
    }

    function start(
        IERC20 _based,
        IERC20 _share,
        ITreasury _treasury
    ) public notStarted {
        based = _based;
        share = _share;
        treasury = _treasury;

        ForgeSnapshot memory genesisSnapshot = ForgeSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        forgeHistory.push(genesisSnapshot);

        started = true;
        emit Started(msg.sender, block.number);
    }

    function setLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyRole(OPERATOR_ROLE) {
        require(_withdrawLockupEpochs >= _rewardLockupEpochs && _withdrawLockupEpochs <= 56, "Forge: _withdrawLockupEpochs out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
        rewardLockupEpochs = _rewardLockupEpochs;
    }

    function latestSnapshotIndex() public view returns (uint256) {
        return forgeHistory.length.sub(1);
    }

    function getLatestSnapshot() internal view returns (ForgeSnapshot memory) {
        return forgeHistory[latestSnapshotIndex()];
    }

    function getLastSnapshotIndexOf(address blacksmith) public view returns (uint256) {
        return blacksmiths[blacksmith].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address blacksmith) internal view returns (ForgeSnapshot memory) {
        return forgeHistory[getLastSnapshotIndexOf(blacksmith)];
    }

    function canWithdraw(address blacksmith) external view returns (bool) {
        return blacksmiths[blacksmith].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function canClaimReward(address blacksmith) external view returns (bool) {
        return blacksmiths[blacksmith].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    function getBasedPrice() external view returns (uint256) {
        return treasury.getBasedPrice();
    }

    function rewardPerShare() public view returns (uint256) {
        return getLatestSnapshot().rewardPerShare;
    }

    function earned(address blacksmith) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot().rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(blacksmith).rewardPerShare;

        return balanceOf(blacksmith).mul(latestRPS.sub(storedRPS)).div(1e18).add(blacksmiths[blacksmith].rewardEarned);
    }

    function stake(uint256 amount) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Forge: Cannot stake 0");
        super.stake(amount);
        blacksmiths[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override onlyOneBlock blacksmithExists updateReward(msg.sender) {
        require(amount > 0, "Forge: Cannot withdraw 0");
        require(blacksmiths[msg.sender].epochTimerStart.add(withdrawLockupEpochs) <= treasury.epoch(), "Forge: Still in withdraw lockup");
        claimReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function claimReward() public updateReward(msg.sender) {
        uint256 reward = blacksmiths[msg.sender].rewardEarned;
        if (reward > 0) {
            require(blacksmiths[msg.sender].epochTimerStart.add(rewardLockupEpochs) <= treasury.epoch(), "Forge: Still in reward lockup");
            blacksmiths[msg.sender].epochTimerStart = treasury.epoch(); // reset timer
            blacksmiths[msg.sender].rewardEarned = 0;
            based.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function allocateSeigniorage(uint256 amount) external onlyOneBlock onlyRole(OPERATOR_ROLE) {
        require(amount > 0, "Forge: Cannot allocate 0");
        require(totalSupply() > 0, "Forge: Cannot allocate when totalSupply is 0");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot().rewardPerShare;
        uint256 nextRPS = prevRPS.add(amount.mul(1e18).div(totalSupply()));

        ForgeSnapshot memory newSnapshot = ForgeSnapshot({
            time: block.number,
            rewardReceived: amount,
            rewardPerShare: nextRPS
        });
        forgeHistory.push(newSnapshot);

        based.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardAdded(msg.sender, amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyRole(OPERATOR_ROLE) {
        // do not allow to drain core tokens
        require(address(_token) != address(based), "Forge: Token cannot be BASED");
        require(address(_token) != address(share), "Forge: Token cannot be bSHARE");
        _token.safeTransfer(_to, _amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}
}
