// SPDX-License-Identifier: MIT

pragma solidity >=0.4.25 <0.7.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IToken.sol";
import "./interfaces/IAuction.sol";
import "./interfaces/IStaking.sol";
import "./interfaces/ISubBalances.sol";

contract Staking is IStaking, AccessControl {
    using SafeMath for uint256;

    uint256 private _sessionsIds;

    bytes32 public constant EXTERNAL_STAKER_ROLE = keccak256(
        "EXTERNAL_STAKER_ROLE"
    );

    struct Payout {
        uint256 payout;
        uint256 sharesTotalSupply;
    }

    struct Session {
        uint256 amount;
        uint256 start;
        uint256 end;
        uint256 shares;
        uint256 nextPayout;
    }

    address public mainToken;
    address public auction;
    address public subBalances;
    uint256 public shareRate;
    uint256 public sharesTotalSupply;
    uint256 public nextPayoutCall;
    uint256 public stepTimestamp;
    uint256 public startContract;
    uint256 public globalPayout;
    uint256 public globalPayin;
    uint256 public lastInflation;
    bool public init_;

    mapping(address => mapping(uint256 => Session)) public sessionDataOf;
    mapping(address => uint256[]) public sessionsOf;
    Payout[] public payouts;

    modifier onlyExternalStaker() {
        require(
            hasRole(EXTERNAL_STAKER_ROLE, _msgSender()),
            "Caller is not a external staker"
        );
        _;
    }

    constructor() public {
        init_ = false;
    }

    function init(
        address _mainToken,
        address _auction,
        address _subBalances,
        address _externalStaker,
        uint256 _stepTimestamp
    ) external {
        require(!init_, "NativeSwap: init is active");
        _setupRole(EXTERNAL_STAKER_ROLE, _externalStaker);
        mainToken = _mainToken;
        auction = _auction;
        subBalances = _subBalances;
        shareRate = 1e18;
        stepTimestamp = _stepTimestamp;
        nextPayoutCall = now.add(_stepTimestamp);
        startContract = now;
        init_ = true;
    }

    function sessionsOf_(address account)
        external
        view
        returns (uint256[] memory)
    {
        return sessionsOf[account];
    }

    function stake(uint256 amount, uint256 stakingDays) external {
        require(stakingDays > 0, "stakingDays < 1");

        uint256 start = now;
        uint256 end = now.add(stakingDays.mul(stepTimestamp));

        IToken(mainToken).burn(msg.sender, amount);
        _sessionsIds = _sessionsIds.add(1);
        uint256 sessionId = _sessionsIds;
        uint256 shares = _getStakersSharesAmount(amount, start, end);
        sharesTotalSupply = sharesTotalSupply.add(shares);

        sessionDataOf[msg.sender][sessionId] = Session({
            amount: amount,
            start: start,
            end: end,
            shares: shares,
            nextPayout: payouts.length
        });

        sessionsOf[msg.sender].push(sessionId);

        // ISubBalances(subBalances).callIncomeStakerTrigger(
        //     msg.sender,
        //     sessionId,
        //     start,
        //     end,
        //     shares
        // );
    }

    function externalStake(
        uint256 amount,
        uint256 stakingDays,
        address staker
    ) external override onlyExternalStaker {
        require(stakingDays > 0, "stakingDays < 1");

        uint256 start = now;
        uint256 end = now.add(stakingDays.mul(stepTimestamp));

        IToken(mainToken).burn(staker, amount);
        _sessionsIds = _sessionsIds.add(1);
        uint256 sessionId = _sessionsIds;
        uint256 shares = _getStakersSharesAmount(amount, start, end);
        sharesTotalSupply = sharesTotalSupply.add(shares);

        sessionDataOf[staker][sessionId] = Session({
            amount: amount,
            start: start,
            end: end,
            shares: shares,
            nextPayout: payouts.length
        });

        sessionsOf[staker].push(sessionId);

        // ISubBalances(subBalances).callIncomeStakerTrigger(
        //     staker,
        //     sessionId,
        //     start,
        //     end,
        //     shares
        // );
    }

    function _initPayout(address to, uint256 amount) internal {
        IToken(mainToken).mint(to, amount);
        globalPayout = globalPayout.add(amount);
    }

    function unstake(uint256 sessionId) external {
        require(
            sessionDataOf[msg.sender][sessionId].shares > 0,
            "NativeSwap: Shares balance is empty"
        );

        require(
            sessionDataOf[msg.sender][sessionId].nextPayout < payouts.length,
            "NativeSwap: No payouts for this session"
        );

        uint256 stakingInterest;

        for (
            uint256 i = sessionDataOf[msg.sender][sessionId].nextPayout;
            i < payouts.length;
            i++
        ) {
            uint256 payout = payouts[i]
                .payout
                .mul(sessionDataOf[msg.sender][sessionId].shares)
                .div(payouts[i].sharesTotalSupply);

            stakingInterest = stakingInterest.add(payout);
        }

        uint256 newShareRate = _getShareRate(
            sessionDataOf[msg.sender][sessionId].amount,
            sessionId,
            sessionDataOf[msg.sender][sessionId].start,
            sessionDataOf[msg.sender][sessionId].end,
            stakingInterest
        );

        if (newShareRate > shareRate) {
            shareRate = newShareRate;
        }

        sharesTotalSupply = sharesTotalSupply.sub(
            sessionDataOf[msg.sender][sessionId].shares
        );

        uint256 stakingDays = (
            sessionDataOf[msg.sender][sessionId].end.sub(
                sessionDataOf[msg.sender][sessionId].start
            )
        )
            .div(stepTimestamp);

        uint256 daysStaked = (
            now.sub(sessionDataOf[msg.sender][sessionId].start)
        )
            .div(stepTimestamp);

        uint256 amountAndInterest = sessionDataOf[msg.sender][sessionId]
            .amount
            .add(stakingInterest);

        // Early
        if (stakingDays > daysStaked) {
            uint256 payOutAmount = amountAndInterest.mul(daysStaked).div(
                stakingDays
            );

            uint256 earlyUnstakePenalty = amountAndInterest.sub(payOutAmount);

            // To auction
            _initPayout(auction, earlyUnstakePenalty);
            // IAuction(auction).callIncomeWeeklyTokensTrigger(
            //     earlyUnstakePenalty
            // );

            // To account
            _initPayout(msg.sender, payOutAmount);

            return;
        }

        // In time
        if (stakingDays <= daysStaked && daysStaked < stakingDays.add(14)) {
            _initPayout(msg.sender, amountAndInterest);
            return;
        }

        // Late
        if (
            stakingDays.add(14) <= daysStaked &&
            daysStaked < stakingDays.add(714)
        ) {
            uint256 daysAfterStaking = daysStaked.sub(stakingDays);

            uint256 payOutAmount = amountAndInterest
                .mul(uint256(714).sub(daysAfterStaking))
                .div(700);

            uint256 lateUnstakePenalty = amountAndInterest.sub(payOutAmount);

            // To auction
            _initPayout(auction, lateUnstakePenalty);
            // IAuction(auction).callIncomeWeeklyTokensTrigger(lateUnstakePenalty);

            // To account
            _initPayout(msg.sender, payOutAmount);

            return;
        }

        // Nothing
        if (stakingDays.add(714) <= daysStaked) {
            // To auction
            _initPayout(auction, amountAndInterest);
            // IAuction(auction).callIncomeWeeklyTokensTrigger(amountAndInterest);
            return;
        }

        // ISubBalances(subBalances).callOutcomeStakerTrigger(
        //     msg.sender,
        //     sessionId,
        //     sessionDataOf[msg.sender][sessionId].start,
        //     sessionDataOf[msg.sender][sessionId].end,
        //     sessionDataOf[msg.sender][sessionId].shares
        // );

        sessionDataOf[msg.sender][sessionId].shares = 0;
    }

    function readUnstake(uint256 sessionId, address account)
        external
        view
        returns (uint256, uint256)
    {
        if (sessionDataOf[account][sessionId].shares == 0) return (0, 0);

        uint256 stakingInterest;

        for (uint256 i = 0; i < payouts.length; i++) {
            uint256 payout = payouts[i]
                .payout
                .mul(sessionDataOf[account][sessionId].shares)
                .div(payouts[i].sharesTotalSupply);

            stakingInterest = stakingInterest.add(payout);
        }

        uint256 stakingDays = (
            sessionDataOf[account][sessionId].end.sub(
                sessionDataOf[account][sessionId].start
            )
        )
            .div(stepTimestamp);

        uint256 daysStaked = (now.sub(sessionDataOf[account][sessionId].start))
            .div(stepTimestamp);

        uint256 amountAndInterest = sessionDataOf[account][sessionId]
            .amount
            .add(stakingInterest);

        // Early
        if (stakingDays > daysStaked) {
            uint256 payOutAmount = amountAndInterest.mul(daysStaked).div(
                stakingDays
            );

            uint256 earlyUnstakePenalty = amountAndInterest.sub(payOutAmount);

            return (payOutAmount, earlyUnstakePenalty);
        }

        // In time
        if (stakingDays <= daysStaked && daysStaked < stakingDays.add(14)) {
            return (amountAndInterest, 0);
        }

        // Late
        if (
            stakingDays.add(14) <= daysStaked &&
            daysStaked < stakingDays.add(714)
        ) {
            uint256 daysAfterStaking = daysStaked.sub(stakingDays);

            uint256 payOutAmount = amountAndInterest
                .mul(uint256(714).sub(daysAfterStaking))
                .div(700);

            uint256 lateUnstakePenalty = amountAndInterest.sub(payOutAmount);

            return (payOutAmount, lateUnstakePenalty);
        }

        // Nothing
        if (stakingDays.add(714) <= daysStaked) {
            return (0, amountAndInterest);
        }
    }

    function makePayout() external {
        require(now >= nextPayoutCall, "NativeSwap: Wrong payout time");
        payouts.push(
            Payout({payout: _getPayout(), sharesTotalSupply: sharesTotalSupply})
        );

        nextPayoutCall = nextPayoutCall.add(stepTimestamp);
    }

    function _getPayout() internal returns (uint256) {
        uint256 amountTokenInDay = IERC20(mainToken).balanceOf(address(this));

        globalPayin = globalPayin.add(amountTokenInDay);

        if (globalPayin > globalPayout) {
            globalPayin = globalPayin.sub(globalPayout);
            globalPayout = 0;
        } else {
            globalPayin = 0;
            globalPayout = 0;
        }

        uint256 currentTokenTotalSupply = (IERC20(mainToken).totalSupply()).add(
            globalPayin
        );

        IToken(mainToken).burn(address(this), amountTokenInDay);

        uint256 inflation = uint256(8)
            .mul(currentTokenTotalSupply.add(sharesTotalSupply))
            .div(36500);

        globalPayin = globalPayin.add(inflation);

        lastInflation = inflation;

        return amountTokenInDay.add(inflation);
    }

    function readPayout() external view returns (uint256) {
        uint256 amountTokenInDay = IERC20(mainToken).balanceOf(address(this));

        uint256 currentTokenTotalSupply = IERC20(mainToken).totalSupply();

        uint256 inflation = uint256(8)
            .mul(currentTokenTotalSupply.add(sharesTotalSupply))
            .div(365);

        uint256 finalAmount = amountTokenInDay.add(inflation);

        return finalAmount;
    }

    function _getStakersSharesAmount(
        uint256 amount,
        uint256 start,
        uint256 end
    ) internal view returns (uint256) {
        uint256 stakingDays = (end.sub(start)).div(stepTimestamp);
        uint256 numerator = amount.mul(uint256(1819).add(stakingDays));
        uint256 denominator = uint256(1820).mul(shareRate);

        return (numerator).mul(1e18).div(denominator);
    }

    function _getShareRate(
        uint256 amount,
        uint256 sessionId,
        uint256 start,
        uint256 end,
        uint256 stakingInterest
    ) internal view returns (uint256) {
        uint256 stakingDays = (end.sub(start)).div(stepTimestamp);

        uint256 numerator = (amount.add(stakingInterest)).mul(
            uint256(1819).add(stakingDays)
        );

        uint256 denominator = uint256(1820).mul(
            sessionDataOf[msg.sender][sessionId].shares
        );

        return (numerator).mul(1e18).div(denominator);
    }

    // Helper
    function getNow0x() external view returns (uint256) {
        return now;
    }
}
