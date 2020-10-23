// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./BPool.sol";
import "./IFaaSPool.sol";

interface IFaaSRewardFund {
    function balance(IERC20 _token) external view returns (uint);
    function safeTransfer(IERC20 _token, address _to, uint _value) external;
}

// This implements BPool contract, and allows for generalized staking, yield farming, and token distribution.
contract FaaSPool is BPool, IFaaSPool {
    using SafeMath for uint;

    // Info of each user.
    struct UserInfo {
        uint amount;
        mapping(uint8 => uint) rewardDebt;
        mapping(uint8 => uint) accumulatedEarned; // will accumulate every time user harvest
        mapping(uint8 => uint) lockReward;
        mapping(uint8 => uint) lockRewardReleased;
        uint lastStakeTime;
    }

    // Info of each rewardPool funding.
    struct RewardPoolInfo {
        IERC20 rewardToken;     // Address of rewardPool token contract.
        uint lastRewardBlock;   // Last block number that rewardPool distribution occurs.
        uint endRewardBlock;    // Block number which rewardPool distribution ends.
        uint rewardPerBlock;    // Reward token amount to distribute per block.
        uint accRewardPerShare; // Accumulated rewardPool per share, times 1e18.

        uint lockRewardPercent; // Lock reward percent - 0 to disable lock & vesting
        uint startVestingBlock; // Block number which vesting starts.
        uint endVestingBlock;   // Block number which vesting ends.
        uint numOfVestingBlocks;

        uint totalPaidRewards;
        uint totalLockedRewards;
    }

    mapping(address => UserInfo) private userInfo;
    RewardPoolInfo[] public rewardPoolInfo;

    IFaaSRewardFund public rewardFund;
    address public exchangeProxy;
    uint public unstakingFrozenTime = 3 days;

    event Deposit(address indexed account, uint256 amount);
    event Withdraw(address indexed account, uint256 amount);

    constructor(address _factory) public BPool(_factory) {
    }

    modifier onlyController() {
        require(msg.sender == controller, "!cntler");
        _;
    }

    function setRewardFund(IFaaSRewardFund _rewardFund) public onlyController {
        rewardFund = _rewardFund;
    }

    function setExchangeProxy(address _exchangeProxy) public onlyController {
        exchangeProxy = _exchangeProxy;
    }

    function setUnstakingFrozenTime(uint _unstakingFrozenTime) public onlyController {
        assert(unstakingFrozenTime <= 30 days); // do not lock fund for too long, please!
        unstakingFrozenTime = _unstakingFrozenTime;
    }

    function addRewardPool(IERC20 _rewardToken, uint256 _startBlock, uint256 _endRewardBlock, uint256 _rewardPerBlock,
        uint256 _lockRewardPercent, uint256 _startVestingBlock, uint256 _endVestingBlock) public onlyController {
        require(_startVestingBlock <= _endVestingBlock, "sVB>eVB");
        _startBlock = (block.number > _startBlock) ? block.number : _startBlock;
        require(_startBlock < _endRewardBlock, "sB>=eB");
        updateReward();
        rewardPoolInfo.push(RewardPoolInfo({
            rewardToken : _rewardToken,
            lastRewardBlock : _startBlock,
            endRewardBlock : _endRewardBlock,
            rewardPerBlock : _rewardPerBlock,
            accRewardPerShare : 0,
            lockRewardPercent : _lockRewardPercent,
            startVestingBlock : _startVestingBlock,
            endVestingBlock : _endVestingBlock,
            numOfVestingBlocks: _endVestingBlock - _startVestingBlock,
            totalPaidRewards: 0,
            totalLockedRewards: 0
            }));
    }

    function updateRewardPool(uint8 _pid, uint256 _endRewardBlock, uint256 _rewardPerBlock) public onlyController {
        updateReward(_pid);
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        require(block.number <= rewardPool.endRewardBlock, "late");
        rewardPool.endRewardBlock = _endRewardBlock;
        rewardPool.rewardPerBlock = _rewardPerBlock;
    }

    function joinPool(uint rewardAmountOut, uint[] calldata maxAmountsIn) external override {
        joinPoolFor(msg.sender, rewardAmountOut, maxAmountsIn);
    }

    function joinPoolFor(address account, uint rewardAmountOut, uint[] calldata maxAmountsIn) public _lock_ {
        require(msg.sender == account || msg.sender == exchangeProxy, "!(prx||own)");
        _joinPool(rewardAmountOut, maxAmountsIn);
        _stakePoolShare(account, rewardAmountOut);
    }

    function joinPoolNotStake(uint rewardAmountOut, uint[] calldata maxAmountsIn) external _lock_ {
        _joinPool(rewardAmountOut, maxAmountsIn);
        _pushPoolShare(msg.sender, rewardAmountOut);
    }

    function _joinPool(uint rewardAmountOut, uint[] calldata maxAmountsIn) internal {
        require(finalized, "!fnl");

        uint rewardTotal = totalSupply();
        uint ratio = bdiv(rewardAmountOut, rewardTotal);
        require(ratio != 0, "erMApr");

        for (uint i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            uint bal = _records[t].balance;
            uint tokenAmountIn = bmul(ratio, bal);
            require(tokenAmountIn != 0 && tokenAmountIn <= maxAmountsIn[i], "erMApr||<limIn");
            _records[t].balance = badd(_records[t].balance, tokenAmountIn);
            emit LOG_JOIN(msg.sender, t, tokenAmountIn);
            _pullUnderlying(t, msg.sender, tokenAmountIn);
        }
        _mintPoolShare(rewardAmountOut);
    }

    function stake(uint _shares) external override {
        uint _before = balanceOf(address(this));
        _pullPoolShare(msg.sender, _shares);
        uint _after = balanceOf(address(this));
        _shares = bsub(_after, _before); // Additional check for deflationary tokens
        _stakePoolShare(msg.sender, _shares);
    }

    function _stakePoolShare(address _account, uint _shares) internal {
        UserInfo storage user = userInfo[_account];
        getAllRewards(_account);
        user.amount = user.amount.add(_shares);
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            user.rewardDebt[_pid] = user.amount.mul(rewardPoolInfo[_pid].accRewardPerShare).div(1e18);
        }
        user.lastStakeTime = block.timestamp;
        emit Deposit(_account, _shares);
    }

    function unfrozenStakeTime(address _account) public view returns (uint) {
        return userInfo[_account].lastStakeTime + unstakingFrozenTime;
    }

    function withdraw(uint _amount) public override {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "am>us.am");
        require(block.timestamp >= user.lastStakeTime.add(unstakingFrozenTime), "frozen");
        getAllRewards(msg.sender);
        user.amount = bsub(user.amount, _amount);
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            user.rewardDebt[_pid] = user.amount.mul(rewardPoolInfo[_pid].accRewardPerShare).div(1e18);
        }
        _pushPoolShare(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }

    // using PUSH pattern for using by Proxy if needed
    function getAllRewards(address _account) public override {
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            getReward(_pid, _account);
        }
    }

    function getReward(uint8 _pid, address _account) public override {
        updateReward(_pid);
        UserInfo storage user = userInfo[_account];
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint _pendingReward = user.amount.mul(rewardPool.accRewardPerShare).div(1e18).sub(user.rewardDebt[_pid]);
        uint _lockRewardPercent = rewardPool.lockRewardPercent;
        if (_lockRewardPercent > 0) {
            if (block.number > rewardPool.endVestingBlock) {
                uint _unlockReward = user.lockReward[_pid].sub(user.lockRewardReleased[_pid]);
                if (_unlockReward > 0) {
                    rewardPool.totalLockedRewards = rewardPool.totalLockedRewards.sub(_unlockReward);
                    _pendingReward = _pendingReward.add(_unlockReward);
                    user.lockRewardReleased[_pid] = user.lockRewardReleased[_pid].add(_unlockReward);
                }
            } else {
                if (_pendingReward > 0) {
                    uint _toLocked = _pendingReward.mul(_lockRewardPercent).div(100);
                    _pendingReward = _pendingReward.sub(_toLocked);
                    user.lockReward[_pid] = user.lockReward[_pid].add(_toLocked);
                    rewardPool.totalLockedRewards = rewardPool.totalLockedRewards.add(_toLocked);
                }
                if (block.number > rewardPool.startVestingBlock) {
                    uint _toReleased = user.lockReward[_pid].mul(block.number.sub(rewardPool.startVestingBlock)).div(rewardPool.numOfVestingBlocks);
                    uint _lockRewardReleased = user.lockRewardReleased[_pid];
                    if (_toReleased > _lockRewardReleased) {
                        uint _unlockReward = _toReleased.sub(_lockRewardReleased);
                        user.lockRewardReleased[_pid] = _lockRewardReleased.add(_unlockReward);
                        rewardPool.totalLockedRewards = rewardPool.totalLockedRewards.sub(_unlockReward);
                        _pendingReward = _pendingReward.add(_unlockReward);
                    }
                }
            }
        }
        if (_pendingReward > 0) {
            user.accumulatedEarned[_pid] = user.accumulatedEarned[_pid].add(_pendingReward);
            rewardPool.totalPaidRewards = rewardPool.totalPaidRewards.add(_pendingReward);
            rewardFund.safeTransfer(rewardPool.rewardToken, _account, _pendingReward);
            user.rewardDebt[_pid] = user.amount.mul(rewardPoolInfo[_pid].accRewardPerShare).div(1e18);
        }
    }

    function pendingReward(uint8 _pid, address _account) public override view returns (uint _pending) {
        UserInfo storage user = userInfo[_account];
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint _accRewardPerShare = rewardPool.accRewardPerShare;
        uint lpSupply = balanceOf(address(this));
        uint _endRewardBlockApplicable = block.number > rewardPool.endRewardBlock ? rewardPool.endRewardBlock : block.number;
        if (_endRewardBlockApplicable > rewardPool.lastRewardBlock && lpSupply != 0) {
            uint _numBlocks = _endRewardBlockApplicable.sub(rewardPool.lastRewardBlock);
            uint _incRewardPerShare = _numBlocks.mul(rewardPool.rewardPerBlock).mul(1e18).div(lpSupply);
            _accRewardPerShare = _accRewardPerShare.add(_incRewardPerShare);
        }
        _pending = user.amount.mul(_accRewardPerShare).div(1e18).sub(user.rewardDebt[_pid]);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() external override {
        UserInfo storage user = userInfo[msg.sender];
        _pushPoolShare(msg.sender, user.amount);
        user.amount = 0;
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            user.rewardDebt[_pid] = 0;
        }
    }

    function getUserInfo(uint8 _pid, address _account) public view returns (uint amount, uint rewardDebt, uint accumulatedEarned, uint lockReward, uint lockRewardReleased) {
        UserInfo storage user = userInfo[_account];
        amount = user.amount;
        rewardDebt = user.rewardDebt[_pid];
        accumulatedEarned = user.accumulatedEarned[_pid];
        lockReward = user.lockReward[_pid];
        lockRewardReleased = user.lockRewardReleased[_pid];
    }

    function exitPool(uint rewardAmountIn, uint[] calldata minAmountsOut) external override _lock_ {
        require(finalized, "!fnl");

        uint rewardTotal = totalSupply();
        uint _exitFee = bmul(rewardAmountIn, exitFee);
        uint pAiAfterExitFee = bsub(rewardAmountIn, _exitFee);
        uint ratio = bdiv(pAiAfterExitFee, rewardTotal);
        require(ratio != 0, "erMApr");

        uint _externalShares = balanceOf(msg.sender);
        if (_externalShares < rewardAmountIn) {
            uint _withdrawShares = bsub(rewardAmountIn, _externalShares);
            uint _stakedShares = userInfo[msg.sender].amount;
            require(_stakedShares >= _withdrawShares, "stk<wdr");
            withdraw(_withdrawShares);
        }

        _pullPoolShare(msg.sender, rewardAmountIn);
        if (_exitFee > 0) {
            _pushPoolShare(factory, _exitFee);
        }
        _burnPoolShare(pAiAfterExitFee);

        for (uint i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            uint bal = _records[t].balance;
            uint tokenAmountOut = bmul(ratio, bal);
            require(tokenAmountOut != 0, "erMApr");
            require(tokenAmountOut >= minAmountsOut[i], "<limO");
            _records[t].balance = bsub(_records[t].balance, tokenAmountOut);
            emit LOG_EXIT(msg.sender, t, tokenAmountOut);
            _pushUnderlying(t, msg.sender, tokenAmountOut);
        }
    }

    function updateReward() public {
        uint8 rewardPoolLength = uint8(rewardPoolInfo.length);
        for (uint8 _pid = 0; _pid < rewardPoolLength; ++_pid) {
            updateReward(_pid);
        }
    }

    function updateReward(uint8 _pid) public {
        RewardPoolInfo storage rewardPool = rewardPoolInfo[_pid];
        uint _endRewardBlockApplicable = block.number > rewardPool.endRewardBlock ? rewardPool.endRewardBlock : block.number;
        if (_endRewardBlockApplicable > rewardPool.lastRewardBlock) {
            uint lpSupply = balanceOf(address(this));
            if (lpSupply > 0) {
                uint _numBlocks = _endRewardBlockApplicable.sub(rewardPool.lastRewardBlock);
                uint _incRewardPerShare = _numBlocks.mul(rewardPool.rewardPerBlock).mul(1e18).div(lpSupply);
                rewardPool.accRewardPerShare = rewardPool.accRewardPerShare.add(_incRewardPerShare);
            }
            rewardPool.lastRewardBlock = _endRewardBlockApplicable;
        }
    }
}