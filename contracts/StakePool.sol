// SPDX-License-Identifier: MIT

pragma solidity 0.7.6;

import "./interfaces/IStakePool.sol";
import "./interfaces/IValueLiquidProvider.sol";
import "./interfaces/IStakePoolController.sol";
import "./interfaces/IStakePoolRewardRebaser.sol";
import "./interfaces/IStakePoolRewardMultiplier.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IValueLiquidPair.sol";
import './libraries/SafeMath.sol';
import './libraries/TransferHelper.sol';
import "./interfaces/IStakePoolRewardFund.sol";

// This implements BPool contract, and allows for generalized staking, yield farming, and token distribution.
contract StakePool is IStakePool {
    using SafeMath for uint;
    uint public override version;
    // Info of each user.
    struct UserInfo {
        uint amount;
        mapping(uint8 => uint) rewardDebt;
        mapping(uint8 => uint) reward;
        mapping(uint8 => uint) accumulatedEarned; // will accumulate every time user harvest
        mapping(uint8 => uint) lockReward;
        mapping(uint8 => uint) lockRewardReleased;
        uint lastStakeTime;
    }

    // Info of each rewardPool funding.
    struct RewardPoolInfo {
        address rewardToken;     // Address of rewardPool token contract.
        address rewardRebaser;     // Address of rewardRebaser contract.
        address rewardMultiplier;     // Address of rewardMultiplier contract.
        uint startRewardBlock;   // Start reward block number that rewardPool distribution occurs.
        uint lastRewardBlock;   // Last block number that rewardPool distribution occurs.
        uint endRewardBlock;    // Block number which rewardPool distribution ends.
        uint rewardPerBlock;    // Reward token amount to distribute per block.
        uint accRewardPerShare; // Accumulated rewardPool per share, times 1e18.

        uint lockRewardPercent; // Lock reward percent - 0 to disable lock & vesting
        uint startVestingBlock; // Block number which vesting starts.
        uint endVestingBlock;   // Block number which vesting ends.
        uint numOfVestingBlocks;

        uint totalPaidRewards;
    }

    mapping(address => UserInfo) public userInfo;
    RewardPoolInfo[] public rewardPoolInfo;
    address public override pair;
    address public rewardFund;
    address public timelock;
    address public controller;

    uint public balance;
    uint public unstakingFrozenTime = 3 days;
    uint private unlocked = 1;
    bool private _initialized = false;
    uint256 public constant BLOCKS_PER_DAY = 6528;

    constructor(address _controller,uint _version) public {
        controller = _controller;
        timelock = msg.sender;
        version = _version;
    }
    modifier lock() {
        require(unlocked == 1, 'StakePool: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }
    modifier onlyTimeLock() {
        require(msg.sender == timelock, "StakePool: !timelock");
        _;
    }

    function allowRecoverRewardToken(address _token) external view override returns (bool) {
        for (uint8 pid = 0; pid < rewardPoolInfo.length; ++pid) {
            RewardPoolInfo storage rewardPool = rewardPoolInfo[pid];
            if (rewardPool.rewardToken == _token) {
                // do not allow to drain reward token if less than 30 days after pool ends
                if (block.number < (rewardPool.endRewardBlock + (BLOCKS_PER_DAY * 30))) {
                    return false;
                }
            }
        }
        return true;
    }
    // called once by the factory at time of deployment
    function initialize(address _pair, uint _unstakingFrozenTime, address _rewardFund, address _timelock) external override {
        require(_initialized == false, "StakePool: Initialize must be false.");
        require(unstakingFrozenTime <= 30 days, "StakePool: unstakingFrozenTime > 30 days");
        pair = _pair;
        unstakingFrozenTime = _unstakingFrozenTime;
        rewardFund = _rewardFund;
        timelock = _timelock;
        _initialized = true;
    }

    function addRewardPool(
        address _rewardToken, address _rewardRebaser, address _rewardMultiplier,
        uint256 _startBlock, uint256 _endRewardBlock,
        uint256 _rewardPerBlock, uint256 _lockRewardPercent,
        uint256 _startVestingBlock, uint256 _endVestingBlock
    ) external override lock onlyTimeLock {
        require(rewardPoolInfo.length <= 16, "StakePool: Reward pool length > 16");
        require(IStakePoolController(controller).isWhitelistRewardRebaser(_rewardRebaser), "StakePool: Invalid reward rebaser");
        require(IStakePoolController(controller).isWhitelistRewardMultiplier(_rewardMultiplier), "StakePool: Invalid reward multiplier");
        require(_startVestingBlock <= _endVestingBlock, "StakePool: startVestingBlock > endVestingBlock");
        _startBlock = (block.number > _startBlock) ? block.number : _startBlock;
        require(_startBlock < _endRewardBlock, "StakePool: startBlock >= endRewardBlock");
        require(_lockRewardPercent <= 100, "StakePool: invalid lockRewardPercent");
        updateReward();
        rewardPoolInfo.push(RewardPoolInfo({
        rewardToken : _rewardToken,
        rewardRebaser : _rewardRebaser,
        startRewardBlock : _startBlock,
        rewardMultiplier : _rewardMultiplier,
        lastRewardBlock : _startBlock,
        endRewardBlock : _endRewardBlock,
        rewardPerBlock : _rewardPerBlock,
        accRewardPerShare : 0,
        lockRewardPercent : _lockRewardPercent,
        startVestingBlock : _startVestingBlock,
        endVestingBlock : _endVestingBlock,
        numOfVestingBlocks : _endVestingBlock - _startVestingBlock,
        totalPaidRewards : 0
        }));
        emit AddRewardPool(rewardPoolInfo.length - 1);
    }

    function updateRewardMultiplier(uint8 _pid, address _rewardMultiplier) external override lock onlyTimeLock {
        require(IStakePoolController(controller).isWhitelistRewardMultiplier(_rewardMultiplier), "StakePool: Invalid reward multiplier");
        updateReward(_pid);
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        rewardPool.rewardMultiplier = _rewardMultiplier;
        emit UpdateRewardMultiplier(_pid, _rewardMultiplier);
    }

    function updateRewardRebaser(uint8 _pid, address _rewardRebaser) external override lock onlyTimeLock {
        require(IStakePoolController(controller).isWhitelistRewardRebaser(_rewardRebaser), "StakePool: Invalid reward rebaser");
        updateReward(_pid);
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        rewardPool.rewardRebaser = _rewardRebaser;
        emit UpdateRewardRebaser(_pid, _rewardRebaser);
    }

    // Return reward multiplier over the given _from to _to block.
    function getRewardMultiplier(uint8 _pid, uint _from, uint _to, uint _rewardPerBlock) public override view returns (uint) {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        address rewardMultiplier = rewardPool.rewardMultiplier;
        if (rewardMultiplier == address(0)) {
            return _to.sub(_from).mul(_rewardPerBlock);
        }
        return IStakePoolRewardMultiplier(rewardMultiplier).getRewardMultiplier(
            rewardPool.startRewardBlock,
            rewardPool.endRewardBlock,
            _from,
            _to,
            _rewardPerBlock
        );
    }

    function getRewardRebase(uint8 _pid, address _rewardToken, uint _pendingReward) public override view returns (uint) {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        address rewardRebaser = rewardPool.rewardRebaser;
        if (rewardRebaser == address(0)) {
            return _pendingReward;
        }
        return IStakePoolRewardRebaser(rewardRebaser).getRebaseAmount(_rewardToken, _pendingReward);
    }

    function getRewardPerBlock(uint8 pid) external override view returns (uint) {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[pid];
        uint rewardPerBlock = rewardPool.rewardPerBlock;
        if (block.number < rewardPool.startRewardBlock || block.number > rewardPool.endRewardBlock) return 0;
        uint reward = getRewardMultiplier(pid, block.number, block.number + 1, rewardPerBlock);
        return getRewardRebase(pid,rewardPool.rewardToken, reward);
    }

    function updateRewardPool(uint8 _pid, uint256 _endRewardBlock, uint256 _rewardPerBlock) external override lock onlyTimeLock {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        require(block.number <= rewardPool.endRewardBlock && block.number <= _endRewardBlock, "StakePool: blockNumber > endRewardBlock");
        updateReward(_pid);
        rewardPool.endRewardBlock = _endRewardBlock;
        rewardPool.rewardPerBlock = _rewardPerBlock;
        emit UpdateRewardPool(_pid, _endRewardBlock, _rewardPerBlock);
    }

    function stake(uint _amount) external lock override {
        IValueLiquidPair(pair).transferFrom(msg.sender, address(this), _amount);
        _stakeFor(msg.sender);
    }

    function stakeFor(address _account) external lock override {
        require(IStakePoolController(controller).isWhitelistStakingFor(msg.sender), "StakePool: Invalid sender");
        _stakeFor(_account);
    }

    function _stakeFor(address _account) internal {
        uint _amount = IValueLiquidPair(pair).balanceOf(address(this)).sub(balance);
        require(_amount > 0, "StakePool: Invalid balance");
        balance = balance.add(_amount);
        UserInfo storage user = userInfo[_account];
        getAllRewards(_account);
        user.amount = user.amount.add(_amount);
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            user.rewardDebt[_pid] = user.amount.mul(rewardPoolInfo[_pid].accRewardPerShare).div(1e18);
        }
        user.lastStakeTime = block.timestamp;
        emit Deposit(_account, _amount);
    }

    function rewardPoolInfoLength() public override view returns (uint) {
        return rewardPoolInfo.length;
    }

    function unfrozenStakeTime(address _account) public override view returns (uint) {
        return userInfo[_account].lastStakeTime + unstakingFrozenTime;
    }
    function removeStakeInternal(uint _amount) internal {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "StakePool: invalid withdraw amount");
        require(block.timestamp >= user.lastStakeTime.add(unstakingFrozenTime), "StakePool: frozen");
        getAllRewards(msg.sender);
        balance = balance.sub(_amount);
        user.amount = user.amount.sub(_amount);
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            user.rewardDebt[_pid] = user.amount.mul(rewardPoolInfo[_pid].accRewardPerShare).div(1e18);
        }
    }
    function withdraw(uint _amount) external lock override {
        removeStakeInternal(_amount);
        IValueLiquidPair(pair).transfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }

    function getAllRewards(address _account) public override {
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            getReward(_pid, _account);
        }
    }
    function claimReward() external override {
        getAllRewards(msg.sender);
    }

    function getReward(uint8 _pid, address _account) public override {
        updateReward(_pid);
        UserInfo storage user = userInfo[_account];
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint _accRewardPerShare = rewardPool.accRewardPerShare;
        uint _pendingReward = user.amount.mul(_accRewardPerShare).div(1e18).sub(user.rewardDebt[_pid]);
        uint _lockRewardPercent = rewardPool.lockRewardPercent;
        if (_lockRewardPercent > 0) {
            if (block.number > rewardPool.endVestingBlock) {
                uint _unlockReward = user.lockReward[_pid].sub(user.lockRewardReleased[_pid]);
                if (_unlockReward > 0) {
                    _pendingReward = _pendingReward.add(_unlockReward);
                    user.lockRewardReleased[_pid] = user.lockRewardReleased[_pid].add(_unlockReward);
                }
            } else {
                if (_pendingReward > 0) {
                    uint _toLocked = _pendingReward.mul(_lockRewardPercent).div(100);
                    _pendingReward = _pendingReward.sub(_toLocked);
                    user.lockReward[_pid] = user.lockReward[_pid].add(_toLocked);
                }
                uint _startVestingBlock = rewardPool.startVestingBlock;
                if (block.number > _startVestingBlock) {
                    uint _toReleased = user.lockReward[_pid].mul(block.number.sub(_startVestingBlock)).div(rewardPool.numOfVestingBlocks);
                    uint _lockRewardReleased = user.lockRewardReleased[_pid];
                    if (_toReleased > _lockRewardReleased) {
                        uint _unlockReward = _toReleased.sub(_lockRewardReleased);
                        user.lockRewardReleased[_pid] = _lockRewardReleased.add(_unlockReward);
                        _pendingReward = _pendingReward.add(_unlockReward);
                    }
                }
            }
        }
        if (_pendingReward > 0) {
            user.accumulatedEarned[_pid] = user.accumulatedEarned[_pid].add(_pendingReward);
            rewardPool.totalPaidRewards = rewardPool.totalPaidRewards.add(_pendingReward);
            user.rewardDebt[_pid] = user.amount.mul(_accRewardPerShare).div(1e18);
            uint reward = user.reward[_pid].add(_pendingReward);
            user.reward[_pid] = reward;
            // Safe reward transfer, just in case if rounding error causes pool to not have enough reward amount
            address rewardToken = rewardPool.rewardToken;
            uint rewardBalance = IERC20(rewardToken).balanceOf(rewardFund);
            if (rewardBalance > 0) {
                user.reward[_pid] = 0;
                uint rebaseAmount = getRewardRebase(_pid, rewardToken, reward);
                uint paidAmount = rebaseAmount > rewardBalance ? rewardBalance : rebaseAmount;
                IStakePoolRewardFund(rewardFund).safeTransfer(rewardToken, _account, paidAmount);
                emit PayRewardPool(_pid, rewardToken, _account, reward, rebaseAmount, paidAmount);
            }
        }
    }


    function pendingReward(uint8 _pid, address _account) external override view returns (uint) {
        UserInfo storage user = userInfo[_account];
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint _accRewardPerShare = rewardPool.accRewardPerShare;
        uint lpSupply = IValueLiquidPair(pair).balanceOf(address(this));
        uint _endRewardBlock = rewardPool.endRewardBlock;
        uint _endRewardBlockApplicable = block.number > _endRewardBlock ? _endRewardBlock : block.number;
        uint _lastRewardBlock = rewardPool.lastRewardBlock;
        if (_endRewardBlockApplicable > _lastRewardBlock && lpSupply != 0) {
            uint _incRewardPerShare = getRewardMultiplier(_pid, _lastRewardBlock, _endRewardBlockApplicable, rewardPool.rewardPerBlock).mul(1e18).div(lpSupply);
            _accRewardPerShare = _accRewardPerShare.add(_incRewardPerShare);
        }
        uint pending = user.amount.mul(_accRewardPerShare).div(1e18).add(user.reward[_pid]).sub(user.rewardDebt[_pid]);
        return getRewardRebase(_pid, rewardPool.rewardToken, pending);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() external lock override {
        require(IStakePoolController(controller).isAllowEmergencyWithdrawStakePool(address(this)),"StakePool: Not allow emergencyWithdraw");
        UserInfo storage user = userInfo[msg.sender];
        uint amount = user.amount;
        balance = balance.sub(amount);
        user.amount = 0;
        IValueLiquidPair(pair).transfer(msg.sender, amount);
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            user.rewardDebt[_pid] = 0;
            user.reward[_pid] = 0;
        }
    }

    function getUserInfo(uint8 _pid, address _account) public override view returns (uint amount, uint rewardDebt, uint accumulatedEarned, uint lockReward, uint lockRewardReleased) {
        UserInfo storage user = userInfo[_account];
        amount = user.amount;
        rewardDebt = user.rewardDebt[_pid];
        accumulatedEarned = user.accumulatedEarned[_pid];
        lockReward = user.lockReward[_pid];
        lockRewardReleased = user.lockRewardReleased[_pid];
    }

    function updateReward() public override {
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            updateReward(_pid);
        }
    }

    function updateReward(uint8 _pid) public override {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint _endRewardBlock = rewardPool.endRewardBlock;
        uint _endRewardBlockApplicable = block.number > _endRewardBlock ? _endRewardBlock : block.number;
        uint _lastRewardBlock = rewardPool.lastRewardBlock;
        if (_endRewardBlockApplicable > _lastRewardBlock) {
            uint lpSupply = IValueLiquidPair(pair).balanceOf(address(this));
            if (lpSupply > 0) {
                uint _incRewardPerShare = getRewardMultiplier(_pid, _lastRewardBlock, _endRewardBlockApplicable, rewardPool.rewardPerBlock).mul(1e18).div(lpSupply);
                rewardPool.accRewardPerShare = rewardPool.accRewardPerShare.add(_incRewardPerShare);
            }
            rewardPool.lastRewardBlock = _endRewardBlockApplicable;
        }
    }

    function removeLiquidity(
        address provider,
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public override lock returns (uint amountA, uint amountB) {
        require(IStakePoolController(controller).isWhitelistStakingFor(provider),"StakePool: Invalid provider");
        removeStakeInternal(liquidity);
        IValueLiquidPair(pair).approve(provider, liquidity);
        emit Withdraw(msg.sender, liquidity);
        (amountA, amountB) = IValueLiquidProvider(provider).removeLiquidity(address(pair), tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    function removeLiquidityETH(
        address provider,
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external override lock returns (uint amountToken, uint amountETH) {
        require(IStakePoolController(controller).isWhitelistStakingFor(provider),"StakePool: Invalid provider");
        removeStakeInternal(liquidity);
        IValueLiquidPair(pair).approve(provider, liquidity);
        emit Withdraw(msg.sender, liquidity);
        (amountToken, amountETH) = IValueLiquidProvider(provider).removeLiquidityETH(address(pair), token, liquidity, amountTokenMin, amountETHMin, to, deadline);

    }

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address provider,
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external override lock returns (uint amountETH) {
        require(IStakePoolController(controller).isWhitelistStakingFor(provider),"StakePool: Invalid provider");
        removeStakeInternal(liquidity);
        IValueLiquidPair(pair).approve(provider, liquidity);
        emit Withdraw(msg.sender, liquidity);
        amountETH = IValueLiquidProvider(provider).removeLiquidityETHSupportingFeeOnTransferTokens(address(pair), token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }



}
