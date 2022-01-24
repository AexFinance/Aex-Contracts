// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/utils/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IVester.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/IAlpManager.sol";
import "../access/Governable.sol";

contract RewardRouterV2 is ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public weth;

    address public aex;
    address public esAex;
    address public bnAex;

    address public alp; // AEX Liquidity Provider token

    address public stakedAexTracker;
    address public bonusAexTracker;
    address public feeAexTracker;

    address public stakedAlpTracker;
    address public feeAlpTracker;

    address public alpManager;

    address public aexVester;
    address public alpVester;

    mapping (address => address) public pendingReceivers;

    event StakeAex(address account, address token, uint256 amount);
    event UnstakeAex(address account, address token, uint256 amount);

    event StakeAlp(address account, uint256 amount);
    event UnstakeAlp(address account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    function initialize(
        address _weth,
        address _aex,
        address _esAex,
        address _bnAex,
        address _alp,
        address _stakedAexTracker,
        address _bonusAexTracker,
        address _feeAexTracker,
        address _feeAlpTracker,
        address _stakedAlpTracker,
        address _alpManager,
        address _aexVester,
        address _alpVester
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;

        weth = _weth;

        aex = _aex;
        esAex = _esAex;
        bnAex = _bnAex;

        alp = _alp;

        stakedAexTracker = _stakedAexTracker;
        bonusAexTracker = _bonusAexTracker;
        feeAexTracker = _feeAexTracker;

        feeAlpTracker = _feeAlpTracker;
        stakedAlpTracker = _stakedAlpTracker;

        alpManager = _alpManager;

        aexVester = _aexVester;
        alpVester = _alpVester;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function batchStakeAexForAccount(address[] memory _accounts, uint256[] memory _amounts) external nonReentrant onlyGov {
        address _aex = aex;
        for (uint256 i = 0; i < _accounts.length; i++) {
            _stakeAex(msg.sender, _accounts[i], _aex, _amounts[i]);
        }
    }

    function stakeAexForAccount(address _account, uint256 _amount) external nonReentrant onlyGov {
        _stakeAex(msg.sender, _account, aex, _amount);
    }

    function stakeAex(uint256 _amount) external nonReentrant {
        _stakeAex(msg.sender, msg.sender, aex, _amount);
    }

    function stakeEsAex(uint256 _amount) external nonReentrant {
        _stakeAex(msg.sender, msg.sender, esAex, _amount);
    }

    function unstakeAex(uint256 _amount) external nonReentrant {
        _unstakeAex(msg.sender, aex, _amount, true);
    }

    function unstakeEsAex(uint256 _amount) external nonReentrant {
        _unstakeAex(msg.sender, esAex, _amount, true);
    }

    function mintAndStakeAlp(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minAlp) external nonReentrant returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");

        address account = msg.sender;
        uint256 alpAmount = IAlpManager(alpManager).addLiquidityForAccount(account, account, _token, _amount, _minUsdg, _minAlp);
        IRewardTracker(feeAlpTracker).stakeForAccount(account, account, alp, alpAmount);
        IRewardTracker(stakedAlpTracker).stakeForAccount(account, account, feeAlpTracker, alpAmount);

        emit StakeAlp(account, alpAmount);

        return alpAmount;
    }

    function mintAndStakeAlpETH(uint256 _minUsdg, uint256 _minAlp) external payable nonReentrant returns (uint256) {
        require(msg.value > 0, "RewardRouter: invalid msg.value");

        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).approve(alpManager, msg.value);

        address account = msg.sender;
        uint256 alpAmount = IAlpManager(alpManager).addLiquidityForAccount(address(this), account, weth, msg.value, _minUsdg, _minAlp);

        IRewardTracker(feeAlpTracker).stakeForAccount(account, account, alp, alpAmount);
        IRewardTracker(stakedAlpTracker).stakeForAccount(account, account, feeAlpTracker, alpAmount);

        emit StakeAlp(account, alpAmount);

        return alpAmount;
    }

    function unstakeAndRedeemAlp(address _tokenOut, uint256 _alpAmount, uint256 _minOut, address _receiver) external nonReentrant returns (uint256) {
        require(_alpAmount > 0, "RewardRouter: invalid _alpAmount");

        address account = msg.sender;
        IRewardTracker(stakedAlpTracker).unstakeForAccount(account, feeAlpTracker, _alpAmount, account);
        IRewardTracker(feeAlpTracker).unstakeForAccount(account, alp, _alpAmount, account);
        uint256 amountOut = IAlpManager(alpManager).removeLiquidityForAccount(account, _tokenOut, _alpAmount, _minOut, _receiver);

        emit UnstakeAlp(account, _alpAmount);

        return amountOut;
    }

    function unstakeAndRedeemAlpETH(uint256 _alpAmount, uint256 _minOut, address payable _receiver) external nonReentrant returns (uint256) {
        require(_alpAmount > 0, "RewardRouter: invalid _alpAmount");

        address account = msg.sender;
        IRewardTracker(stakedAlpTracker).unstakeForAccount(account, feeAlpTracker, _alpAmount, account);
        IRewardTracker(feeAlpTracker).unstakeForAccount(account, alp, _alpAmount, account);
        uint256 amountOut = IAlpManager(alpManager).removeLiquidityForAccount(account, weth, _alpAmount, _minOut, address(this));

        IWETH(weth).withdraw(amountOut);

        _receiver.sendValue(amountOut);

        emit UnstakeAlp(account, _alpAmount);

        return amountOut;
    }

    function claim() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeAexTracker).claimForAccount(account, account);
        IRewardTracker(feeAlpTracker).claimForAccount(account, account);

        IRewardTracker(stakedAexTracker).claimForAccount(account, account);
        IRewardTracker(stakedAlpTracker).claimForAccount(account, account);
    }

    function claimEsAex() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(stakedAexTracker).claimForAccount(account, account);
        IRewardTracker(stakedAlpTracker).claimForAccount(account, account);
    }

    function claimFees() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeAexTracker).claimForAccount(account, account);
        IRewardTracker(feeAlpTracker).claimForAccount(account, account);
    }

    function compound() external nonReentrant {
        _compound(msg.sender);
    }

    function compoundForAccount(address _account) external nonReentrant onlyGov {
        _compound(_account);
    }

    function handleRewards(
        bool _shouldClaimAex,
        bool _shouldStakeAex,
        bool _shouldClaimEsAex,
        bool _shouldStakeEsAex,
        bool _shouldStakeMultiplierPoints,
        bool _shouldClaimWeth,
        bool _shouldConvertWethToEth
    ) external nonReentrant {
        address account = msg.sender;

        uint256 aexAmount = 0;
        if (_shouldClaimAex) {
            uint256 aexAmount0 = IVester(aexVester).claimForAccount(account, account);
            uint256 aexAmount1 = IVester(alpVester).claimForAccount(account, account);
            aexAmount = aexAmount0.add(aexAmount1);
        }

        if (_shouldStakeAex && aexAmount > 0) {
            _stakeAex(account, account, aex, aexAmount);
        }

        uint256 esAexAmount = 0;
        if (_shouldClaimEsAex) {
            uint256 esAexAmount0 = IRewardTracker(stakedAexTracker).claimForAccount(account, account);
            uint256 esAexAmount1 = IRewardTracker(stakedAlpTracker).claimForAccount(account, account);
            esAexAmount = esAexAmount0.add(esAexAmount1);
        }

        if (_shouldStakeEsAex && esAexAmount > 0) {
            _stakeAex(account, account, esAex, esAexAmount);
        }

        if (_shouldStakeMultiplierPoints) {
            uint256 bnAexAmount = IRewardTracker(bonusAexTracker).claimForAccount(account, account);
            if (bnAexAmount > 0) {
                IRewardTracker(feeAexTracker).stakeForAccount(account, account, bnAex, bnAexAmount);
            }
        }

        if (_shouldClaimWeth) {
            if (_shouldConvertWethToEth) {
                uint256 weth0 = IRewardTracker(feeAexTracker).claimForAccount(account, address(this));
                uint256 weth1 = IRewardTracker(feeAlpTracker).claimForAccount(account, address(this));

                uint256 wethAmount = weth0.add(weth1);
                IWETH(weth).withdraw(wethAmount);

                payable(account).sendValue(wethAmount);
            } else {
                IRewardTracker(feeAexTracker).claimForAccount(account, account);
                IRewardTracker(feeAlpTracker).claimForAccount(account, account);
            }
        }
    }

    function batchCompoundForAccounts(address[] memory _accounts) external nonReentrant onlyGov {
        for (uint256 i = 0; i < _accounts.length; i++) {
            _compound(_accounts[i]);
        }
    }

    function signalTransfer(address _receiver) external nonReentrant {
        require(IERC20(aexVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");
        require(IERC20(alpVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");

        _validateReceiver(_receiver);
        pendingReceivers[msg.sender] = _receiver;
    }

    function acceptTransfer(address _sender) external nonReentrant {
        require(IERC20(aexVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");
        require(IERC20(alpVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");

        address receiver = msg.sender;
        require(pendingReceivers[_sender] == receiver, "RewardRouter: transfer not signalled");
        delete pendingReceivers[_sender];

        _validateReceiver(receiver);
        _compound(_sender);

        uint256 stakedAex = IRewardTracker(stakedAexTracker).depositBalances(_sender, aex);
        if (stakedAex > 0) {
            _unstakeAex(_sender, aex, stakedAex, false);
            _stakeAex(_sender, receiver, aex, stakedAex);
        }

        uint256 stakedEsAex = IRewardTracker(stakedAexTracker).depositBalances(_sender, esAex);
        if (stakedEsAex > 0) {
            _unstakeAex(_sender, esAex, stakedEsAex, false);
            _stakeAex(_sender, receiver, esAex, stakedEsAex);
        }

        uint256 stakedBnAex = IRewardTracker(feeAexTracker).depositBalances(_sender, bnAex);
        if (stakedBnAex > 0) {
            IRewardTracker(feeAexTracker).unstakeForAccount(_sender, bnAex, stakedBnAex, _sender);
            IRewardTracker(feeAexTracker).stakeForAccount(_sender, receiver, bnAex, stakedBnAex);
        }

        uint256 esAexBalance = IERC20(esAex).balanceOf(_sender);
        if (esAexBalance > 0) {
            IERC20(esAex).transferFrom(_sender, receiver, esAexBalance);
        }

        uint256 alpAmount = IRewardTracker(feeAlpTracker).depositBalances(_sender, alp);
        if (alpAmount > 0) {
            IRewardTracker(stakedAlpTracker).unstakeForAccount(_sender, feeAlpTracker, alpAmount, _sender);
            IRewardTracker(feeAlpTracker).unstakeForAccount(_sender, alp, alpAmount, _sender);

            IRewardTracker(feeAlpTracker).stakeForAccount(_sender, receiver, alp, alpAmount);
            IRewardTracker(stakedAlpTracker).stakeForAccount(receiver, receiver, feeAlpTracker, alpAmount);
        }

        IVester(aexVester).transferStakeValues(_sender, receiver);
        IVester(alpVester).transferStakeValues(_sender, receiver);
    }

    function _validateReceiver(address _receiver) private view {
        require(IRewardTracker(stakedAexTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: stakedAexTracker.averageStakedAmounts > 0");
        require(IRewardTracker(stakedAexTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: stakedAexTracker.cumulativeRewards > 0");

        require(IRewardTracker(bonusAexTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: bonusAexTracker.averageStakedAmounts > 0");
        require(IRewardTracker(bonusAexTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: bonusAexTracker.cumulativeRewards > 0");

        require(IRewardTracker(feeAexTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeAexTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeAexTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeAexTracker.cumulativeRewards > 0");

        require(IVester(aexVester).transferredAverageStakedAmounts(_receiver) == 0, "RewardRouter: aexVester.transferredAverageStakedAmounts > 0");
        require(IVester(aexVester).transferredCumulativeRewards(_receiver) == 0, "RewardRouter: aexVester.transferredCumulativeRewards > 0");

        require(IRewardTracker(stakedAlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: stakedAlpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(stakedAlpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: stakedAlpTracker.cumulativeRewards > 0");

        require(IRewardTracker(feeAlpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeAlpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeAlpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeAlpTracker.cumulativeRewards > 0");

        require(IVester(alpVester).transferredAverageStakedAmounts(_receiver) == 0, "RewardRouter: aexVester.transferredAverageStakedAmounts > 0");
        require(IVester(alpVester).transferredCumulativeRewards(_receiver) == 0, "RewardRouter: aexVester.transferredCumulativeRewards > 0");

        require(IERC20(aexVester).balanceOf(_receiver) == 0, "RewardRouter: aexVester.balance > 0");
        require(IERC20(alpVester).balanceOf(_receiver) == 0, "RewardRouter: alpVester.balance > 0");
    }

    function _compound(address _account) private {
        _compoundAex(_account);
        _compoundAlp(_account);
    }

    function _compoundAex(address _account) private {
        uint256 esAexAmount = IRewardTracker(stakedAexTracker).claimForAccount(_account, _account);
        if (esAexAmount > 0) {
            _stakeAex(_account, _account, esAex, esAexAmount);
        }

        uint256 bnAexAmount = IRewardTracker(bonusAexTracker).claimForAccount(_account, _account);
        if (bnAexAmount > 0) {
            IRewardTracker(feeAexTracker).stakeForAccount(_account, _account, bnAex, bnAexAmount);
        }
    }

    function _compoundAlp(address _account) private {
        uint256 esAexAmount = IRewardTracker(stakedAlpTracker).claimForAccount(_account, _account);
        if (esAexAmount > 0) {
            _stakeAex(_account, _account, esAex, esAexAmount);
        }
    }

    function _stakeAex(address _fundingAccount, address _account, address _token, uint256 _amount) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        IRewardTracker(stakedAexTracker).stakeForAccount(_fundingAccount, _account, _token, _amount);
        IRewardTracker(bonusAexTracker).stakeForAccount(_account, _account, stakedAexTracker, _amount);
        IRewardTracker(feeAexTracker).stakeForAccount(_account, _account, bonusAexTracker, _amount);

        emit StakeAex(_account, _token, _amount);
    }

    function _unstakeAex(address _account, address _token, uint256 _amount, bool _shouldReduceBnAex) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(stakedAexTracker).stakedAmounts(_account);

        IRewardTracker(feeAexTracker).unstakeForAccount(_account, bonusAexTracker, _amount, _account);
        IRewardTracker(bonusAexTracker).unstakeForAccount(_account, stakedAexTracker, _amount, _account);
        IRewardTracker(stakedAexTracker).unstakeForAccount(_account, _token, _amount, _account);

        if (_shouldReduceBnAex) {
            uint256 bnAexAmount = IRewardTracker(bonusAexTracker).claimForAccount(_account, _account);
            if (bnAexAmount > 0) {
                IRewardTracker(feeAexTracker).stakeForAccount(_account, _account, bnAex, bnAexAmount);
            }

            uint256 stakedBnAex = IRewardTracker(feeAexTracker).depositBalances(_account, bnAex);
            if (stakedBnAex > 0) {
                uint256 reductionAmount = stakedBnAex.mul(_amount).div(balance);
                IRewardTracker(feeAexTracker).unstakeForAccount(_account, bnAex, reductionAmount, _account);
                IMintable(bnAex).burn(_account, reductionAmount);
            }
        }

        emit UnstakeAex(_account, _token, _amount);
    }
}
