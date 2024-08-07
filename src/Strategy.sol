// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ITermRepoToken} from "./interfaces/term/ITermRepoToken.sol";
import {ITermRepoServicer} from "./interfaces/term/ITermRepoServicer.sol";
import {ITermController} from "./interfaces/term/ITermController.sol";
import {ITermVaultEvents} from "./interfaces/term/ITermVaultEvents.sol";
import {ITermAuctionOfferLocker} from "./interfaces/term/ITermAuctionOfferLocker.sol";
import {ITermRepoCollateralManager} from "./interfaces/term/ITermRepoCollateralManager.sol";
import {ITermDiscountRateAdapter} from "./interfaces/term/ITermDiscountRateAdapter.sol";
import {ITermAuction} from "./interfaces/term/ITermAuction.sol";
import {RepoTokenList, RepoTokenListData} from "./RepoTokenList.sol";
import {TermAuctionList, TermAuctionListData, PendingOffer} from "./TermAuctionList.sol";
import {RepoTokenUtils} from "./RepoTokenUtils.sol";

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

contract Strategy is BaseStrategy, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using RepoTokenList for RepoTokenListData;
    using TermAuctionList for TermAuctionListData;

    // Errors
    error InvalidTermAuction(address auction);
    error TimeToMaturityAboveThreshold();
    error BalanceBelowliquidityReserveRatio();
    error InsufficientLiquidBalance(uint256 have, uint256 want);
    error RepoTokenConcentrationTooHigh(address repoToken);

    // Immutable state variables
    ITermVaultEvents public immutable TERM_VAULT_EVENT_EMITTER;
    uint256 public immutable PURCHASE_TOKEN_PRECISION;
    IERC4626 public immutable YEARN_VAULT;

    // State variables
    ITermController public termController;
    ITermDiscountRateAdapter public discountRateAdapter;
    RepoTokenListData internal repoTokenListData;
    TermAuctionListData internal termAuctionListData;
    uint256 public timeToMaturityThreshold; // seconds
    uint256 public liquidityReserveRatio; // purchase token precision (underlying)
    uint256 public discountRateMarkup; // 1e18 (TODO: check this)
    uint256 public repoTokenConcentrationLimit;

    /*//////////////////////////////////////////////////////////////
                    MANAGEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rescue tokens from the contract
     * @param token The address of the token to rescue
     * @param amount The amount of tokens to rescue
     */
    function rescueToken(
        address token,
        uint256 amount
    ) external onlyManagement {
        if (amount > 0) {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyManagement {
        _pause();
        TERM_VAULT_EVENT_EMITTER.emitPaused();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyManagement {
        _unpause();
        TERM_VAULT_EVENT_EMITTER.emitUnpaused();
    }

    /**
     * @notice Set the term controller
     * @param newTermController The address of the new term controller
     */
    function setTermController(
        address newTermController
    ) external onlyManagement {
        require(newTermController != address(0));
        TERM_VAULT_EVENT_EMITTER.emitTermControllerUpdated(
            address(termController),
            newTermController
        );
        termController = ITermController(newTermController);
    }

    /**
     * @notice Set the discount rate adapter used to price repoTokens
     * @param newAdapter The address of the new discount rate adapter
     */
    function setDiscountRateAdapter(
        address newAdapter
    ) external onlyManagement {
        TERM_VAULT_EVENT_EMITTER.emitDiscountRateAdapterUpdated(
            address(discountRateAdapter),
            newAdapter
        );
        discountRateAdapter = ITermDiscountRateAdapter(newAdapter);
    }

    /**
     * @notice Set the weighted time to maturity cap
     * @param newTimeToMaturityThreshold The new weighted time to maturity cap
     */
    function setTimeToMaturityThreshold(
        uint256 newTimeToMaturityThreshold
    ) external onlyManagement {
        TERM_VAULT_EVENT_EMITTER.emitTimeToMaturityThresholdUpdated(
            timeToMaturityThreshold,
            newTimeToMaturityThreshold
        );
        timeToMaturityThreshold = newTimeToMaturityThreshold;
    }

    /**
     * @notice Set the liquidity reserve factor
     * @param newliquidityReserveRatio The new liquidity reserve factor
     */
    function setliquidityReserveRatio(
        uint256 newliquidityReserveRatio
    ) external onlyManagement {
        TERM_VAULT_EVENT_EMITTER.emitliquidityReserveRatioUpdated(
            liquidityReserveRatio,
            newliquidityReserveRatio
        );
        liquidityReserveRatio = newliquidityReserveRatio;
    }

    /**
     * @notice Set the repoToken concentration limit
     * @param newRepoTokenConcentrationLimit The new repoToken concentration limit
     */
    function setRepoTokenConcentrationLimit(
        uint256 newRepoTokenConcentrationLimit
    ) external onlyManagement {
        TERM_VAULT_EVENT_EMITTER.emitRepoTokenConcentrationLimitUpdated(
            repoTokenConcentrationLimit,
            newRepoTokenConcentrationLimit
        );
        repoTokenConcentrationLimit = newRepoTokenConcentrationLimit;
    }

    /**
     * @notice Set the markup that the vault will receive in excess of the oracle rate
     * @param newdiscountRateMarkup The new auction rate markup
     */
    function setdiscountRateMarkup(
        uint256 newdiscountRateMarkup
    ) external onlyManagement {
        TERM_VAULT_EVENT_EMITTER.emitdiscountRateMarkupUpdated(
            discountRateMarkup,
            newdiscountRateMarkup
        );
        discountRateMarkup = newdiscountRateMarkup;
    }

    /**
     * @notice Set the collateral token parameters
     * @param tokenAddr The address of the collateral token to be accepted
     * @param minCollateralRatio The minimum collateral ratio accepted by the strategy
     */
    function setCollateralTokenParams(
        address tokenAddr,
        uint256 minCollateralRatio
    ) external onlyManagement {
        TERM_VAULT_EVENT_EMITTER.emitMinCollateralRatioUpdated(
            tokenAddr,
            minCollateralRatio
        );
        repoTokenListData.collateralTokenParams[tokenAddr] = minCollateralRatio;
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/


    /**
     * @notice Calculates the total value of all assets managed by the strategy
     * @return The total asset value in the purchase token precision
     *
     * @dev This function aggregates the total liquid balance, the present value of all repoTokens,
     * and the present value of all pending offers to calculate the total asset value.     
     */
    function totalAssetValue() external view returns (uint256) {
        return _totalAssetValue();
    }

    /**
     * @notice Get the total liquid balance of the assets managed by the strategy
     * @return The total liquid balance in the purchase token precision
     *
     * @dev This function aggregates the balance of the underlying asset held directly by the strategy
     * and the balance of the asset held in the Yearn Vault to calculate the total liquid balance.     
     */
    function totalLiquidBalance() external view returns (uint256) {
        return _totalLiquidBalance(address(this));
    }

    /**
     * @notice Returns an array of addresses representing the repoTokens currently held by the strategy
     * @return address[] An array of addresses of the repoTokens held by the strategy
     *
     * @dev This function calls the `holdings` function from the `RepoTokenList` library to get the list
     * of repoTokens currently held in the `RepoTokenListData` structure.
     */
    function repoTokenHoldings() external view returns (address[] memory) {
        return repoTokenListData.holdings();
    }

    /**
     * @notice Get an array of pending offers submitted into Term auctions
     * @return bytes32[] An array of `bytes32` values representing the IDs of the pending offers
     *
     * @dev This function calls the `pendingOffers` function from the `TermAuctionList` library to get the list
     * of pending offers currently submitted into Term auctions from the `TermAuctionListData` structure.
     */
    function pendingOffers() external view returns (bytes32[] memory) {
        return termAuctionListData.pendingOffers();
    }

    /**
     * @notice Simulates the weighted time to maturity for a specified repoToken and amount, including the impact on the entire strategy's holdings
     * @param repoToken The address of the repoToken to be simulated
     * @param amount The amount of the repoToken to be simulated
     * @return uint256 The simulated weighted time to maturity for the entire strategy
     *
     * @dev This function validates the repoToken, normalizes its amount, checks concentration limits,
     * and calculates the weighted time to maturity for the specified repoToken and amount. The result
     * reflects the new weighted time to maturity for the entire strategy, including the new repoToken position.
     */
    function simulateWeightedTimeToMaturity(
        address repoToken,
        uint256 amount
    ) external view returns (uint256) {
        // do not validate if we are simulating with existing repoTokens
        if (repoToken != address(0)) {
            repoTokenListData.validateRepoToken(
                ITermRepoToken(repoToken),
                termController,
                address(asset)
            );

            uint256 repoTokenPrecision = 10 ** ERC20(repoToken).decimals();
            uint256 repoTokenAmountInBaseAssetPrecision = (ITermRepoToken(
                repoToken
            ).redemptionValue() *
                amount *
                PURCHASE_TOKEN_PRECISION) /
                (repoTokenPrecision * RepoTokenUtils.RATE_PRECISION);
            _validateRepoTokenConcentration(
                repoToken,
                repoTokenAmountInBaseAssetPrecision,
                0
            );
        }

        return
            _calculateWeightedMaturity(
                repoToken,
                amount,
                _totalLiquidBalance(address(this))
            );
    }

    /**
     * @notice Calculates the present value of a specified repoToken based on its discount rate, redemption timestamp, and amount
     * @param repoToken The address of the repoToken
     * @param discountRate The discount rate to be used in the present value calculation
     * @param amount The amount of the repoToken to be discounted
     * @return uint256 The present value of the specified repoToken and amount
     *
     * @dev This function retrieves the redemption timestamp, calculates the repoToken precision,
     * normalizes the repoToken amount to base asset precision, and calculates the present value
     * using the provided discount rate and redemption timestamp.
     */
    function calculateRepoTokenPresentValue(
        address repoToken,
        uint256 discountRate,
        uint256 amount
    ) external view returns (uint256) {
        (uint256 redemptionTimestamp, , , ) = ITermRepoToken(repoToken)
            .config();
        uint256 repoTokenPrecision = 10 ** ERC20(repoToken).decimals();
        uint256 repoTokenAmountInBaseAssetPrecision = (ITermRepoToken(repoToken)
            .redemptionValue() *
            amount *
            PURCHASE_TOKEN_PRECISION) /
            (repoTokenPrecision * RepoTokenUtils.RATE_PRECISION);
        return
            RepoTokenUtils.calculatePresentValue(
                repoTokenAmountInBaseAssetPrecision,
                PURCHASE_TOKEN_PRECISION,
                redemptionTimestamp,
                discountRate
            );
    }

    /**
     * @notice Calculates the present value of a specified repoToken held by the strategy
     * @param repoToken The address of the repoToken to value
     * @return uint256 The present value of the specified repoToken
     *
     * @dev This function calculates the present value of the specified repoToken from both
     * the `repoTokenListData` and `termAuctionListData` structures, then sums these values
     * to provide a comprehensive valuation.
     */
    function getRepoTokenHoldingValue(
        address repoToken
    ) public view returns (uint256) {
        return
            repoTokenListData.getPresentValue(
                PURCHASE_TOKEN_PRECISION,
                repoToken
            ) +
            termAuctionListData.getPresentValue(
                repoTokenListData,
                discountRateAdapter,
                PURCHASE_TOKEN_PRECISION,
                repoToken
            );
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Withdraw assets from the Yearn vault
     * @param amount The amount to withdraw
     */
    function _withdrawAsset(uint256 amount) private {
        YEARN_VAULT.withdraw(
            YEARN_VAULT.convertToShares(amount),
            address(this),
            address(this)
        );
    }

    /**
     * @dev Retrieves the asset balance from the Yearn Vault
     * @return The balance of assets in the purchase token precision
     */
    function _assetBalance() private view returns (uint256) {
        return
            YEARN_VAULT.convertToAssets(YEARN_VAULT.balanceOf(address(this)));
    }

    /**
     * @notice Calculates the total liquid balance of the assets managed by the strategy
     * @param addr The address of the strategy or contract that holds the assets
     * @return uint256 The total liquid balance of the assets
     *
     * @dev This function aggregates the balance of the underlying asset held directly by the strategy
     * and the balance of the asset held in the Yearn Vault to calculate the total liquid balance.
     */
    function _totalLiquidBalance(address addr) private view returns (uint256) {
        uint256 underlyingBalance = IERC20(asset).balanceOf(address(this));
        return _assetBalance() + underlyingBalance;
    }

    /**
     * @notice Calculates the total value of all assets managed by the strategy (internal function)
     * @return uint256 The total value of all assets
     *
     * @dev This function aggregates the total liquid balance, the present value of all repoTokens,
     * and the present value of all pending offers to calculate the total asset value.
     */
    function _totalAssetValue() internal view returns (uint256 totalValue) {
        return
            _totalLiquidBalance(address(this)) +
            repoTokenListData.getPresentValue(
                PURCHASE_TOKEN_PRECISION,
                address(0)
            ) +
            termAuctionListData.getPresentValue(
                repoTokenListData,
                discountRateAdapter,
                PURCHASE_TOKEN_PRECISION,
                address(0)
            );
    }

    /**
     * @dev Validate the concentration of repoTokens
     * @param repoToken The address of the repoToken
     * @param repoTokenAmountInBaseAssetPrecision The amount of the repoToken in base asset precision
     * @param liquidBalanceToRemove The liquid balance to remove
     */
    function _validateRepoTokenConcentration(
        address repoToken,
        uint256 repoTokenAmountInBaseAssetPrecision,
        uint256 liquidBalanceToRemove
    ) private view {
        // Retrieve the current value of the repoToken held by the strategy and add the new repoToken amount
        uint256 repoTokenValue = getRepoTokenHoldingValue(repoToken) +
            repoTokenAmountInBaseAssetPrecision;

        // Retrieve the total asset value of the strategy and adjust it for the new repoToken amount and liquid balance to be removed            
        uint256 totalAsseValue = _totalAssetValue() +
            repoTokenAmountInBaseAssetPrecision -
            liquidBalanceToRemove;

        // Normalize the repoToken value and total asset value to 1e18 precision
        repoTokenValue = (repoTokenValue * 1e18) / PURCHASE_TOKEN_PRECISION;
        totalAsseValue = (totalAsseValue * 1e18) / PURCHASE_TOKEN_PRECISION;

        // Calculate the repoToken concentration
        uint256 repoTokenConcentration = totalAsseValue == 0
            ? 0
            : (repoTokenValue * 1e18) / totalAsseValue;

        // Check if the repoToken concentration exceeds the predefined limit
        if (repoTokenConcentration > repoTokenConcentrationLimit) {
            revert RepoTokenConcentrationTooHigh(repoToken);
        }
    }

    /**
     * @notice Validates the resulting weighted time to maturity when submitting a new offer
     * @param repoToken The address of the repoToken associated with the Term auction offer
     * @param newOfferAmount The amount associated with the Term auction offer
     * @param newLiquidBalance The new liquid balance of the strategy after accounting for the new offer
     *
     * @dev This function calculates the resulting weighted time to maturity assuming that a submitted offer is accepted
     * and checks if it exceeds the predefined threshold (`timeToMaturityThreshold`). If the threshold is exceeded,
     * the function reverts the transaction with an error.
     */
    function _validateWeightedMaturity(
        address repoToken,
        uint256 newOfferAmount,
        uint256 newLiquidBalance
    ) private {
        // Calculate the precision of the repoToken        
        uint256 repoTokenPrecision = 10 ** ERC20(repoToken).decimals();

        // Convert the new offer amount to repoToken precision        
        uint256 offerAmountInRepoPrecision = RepoTokenUtils
            .purchaseToRepoPrecision(
                repoTokenPrecision,
                PURCHASE_TOKEN_PRECISION,
                newOfferAmount
            );

        // Calculate the resulting weighted time to maturity            
        uint256 resultingWeightedTimeToMaturity = _calculateWeightedMaturity(
            repoToken,
            offerAmountInRepoPrecision,
            newLiquidBalance
        );

        // Check if the resulting weighted time to maturity exceeds the threshold
        if (resultingWeightedTimeToMaturity > timeToMaturityThreshold) {
            revert TimeToMaturityAboveThreshold();
        }
    }
    
    /**
     * @notice Calculates the weighted time to maturity for the strategy's holdings, including the impact of a specified repoToken and amount
     * @param repoToken The address of the repoToken (optional)
     * @param repoTokenAmount The amount of the repoToken to be included in the calculation
     * @param liquidBalance The liquid balance of the strategy
     * @return uint256 The weighted time to maturity in seconds for the entire strategy, including the specified repoToken and amount
     *
     * @dev This function aggregates the cumulative weighted time to maturity and the cumulative amount of both existing repoTokens
     * and offers, then calculates the weighted time to maturity for the entire strategy. It considers both repoTokens and auction offers.
     * The `repoToken` and `repoTokenAmount` parameters are optional and provide flexibility to adjust the calculations to include
     * the provided repoToken amount. If `repoToken` is set to `address(0)` or `repoTokenAmount` is `0`, the function calculates
     * the cumulative data without specific token adjustments.     
     */
    function _calculateWeightedMaturity(
        address repoToken,
        uint256 repoTokenAmount,
        uint256 liquidBalance
    ) private view returns (uint256) {

        // Initialize cumulative weighted time to maturity and cumulative amount        
        uint256 cumulativeWeightedTimeToMaturity; // in seconds
        uint256 cumulativeAmount; // in purchase token precision

        // Get cumulative data from repoToken list
        (
            uint256 cumulativeRepoTokenWeightedTimeToMaturity,
            uint256 cumulativeRepoTokenAmount,
            bool foundInRepoTokenList
        ) = repoTokenListData.getCumulativeRepoTokenData(
                repoToken,
                repoTokenAmount,
                PURCHASE_TOKEN_PRECISION,
                liquidBalance
            );

        // Accumulate repoToken data
        cumulativeWeightedTimeToMaturity += cumulativeRepoTokenWeightedTimeToMaturity;
        cumulativeAmount += cumulativeRepoTokenAmount;

        (
            uint256 cumulativeOfferWeightedTimeToMaturity,
            uint256 cumulativeOfferAmount,
            bool foundInOfferList
        ) = termAuctionListData.getCumulativeOfferData(
                repoTokenListData,
                termController,
                repoToken,
                repoTokenAmount,
                PURCHASE_TOKEN_PRECISION
            );

        // Accumulate offer data
        cumulativeWeightedTimeToMaturity += cumulativeOfferWeightedTimeToMaturity;
        cumulativeAmount += cumulativeOfferAmount;

        if (
            !foundInRepoTokenList &&
            !foundInOfferList &&
            repoToken != address(0)
        ) {
            uint256 repoTokenAmountInBaseAssetPrecision = RepoTokenUtils
                .getNormalizedRepoTokenAmount(
                    repoToken,
                    repoTokenAmount,
                    PURCHASE_TOKEN_PRECISION
                );

            cumulativeAmount += repoTokenAmountInBaseAssetPrecision;
            cumulativeWeightedTimeToMaturity += RepoTokenList
                .getRepoTokenWeightedTimeToMaturity(
                    repoToken,
                    repoTokenAmountInBaseAssetPrecision
                );
        }

        // Avoid division by zero
        if (cumulativeAmount == 0 && liquidBalance == 0) {
            return 0;
        }

        // Calculate and return weighted time to maturity
        // time * purchaseTokenPrecision / purchaseTokenPrecision
        return
            cumulativeWeightedTimeToMaturity /
            (cumulativeAmount + liquidBalance);
    }

    /**
     * @notice Rebalances the strategy's assets by sweeping assets and redeeming matured repoTokens
     * @param liquidAmountRequired The amount of liquid assets required to be maintained by the strategy
     *
     * @dev This function removes completed auction offers, redeems matured repoTokens, and adjusts the underlying
     * balance to maintain the required liquidity. It ensures that the strategy has sufficient liquid assets while
     * optimizing asset allocation.    
     */
    function _sweepAssetAndRedeemRepoTokens(
        uint256 liquidAmountRequired
    ) private {
        // Remove completed auction offers
        termAuctionListData.removeCompleted(
            repoTokenListData,
            termController,
            discountRateAdapter,
            address(asset)
        );

        // Remove and redeem matured repoTokens
        repoTokenListData.removeAndRedeemMaturedTokens();

        // Retrieve the balance of the underlying asset held directly by the strategy
        uint256 underlyingBalance = IERC20(asset).balanceOf(address(this));

        // Deposit excess underlying balance into Yearn Vault
        if (underlyingBalance > liquidAmountRequired) {
            unchecked {
                YEARN_VAULT.deposit(
                    underlyingBalance - liquidAmountRequired,
                    address(this)
                );
            }
        // Withdraw shortfall from Yearn Vault to meet required liquidity            
        } else if (underlyingBalance < liquidAmountRequired) {
            unchecked {
                _withdrawAsset(liquidAmountRequired - underlyingBalance);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    STRATEGIST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Submits an offer into a term auction for a specified repoToken
     * @param termAuction The address of the term auction
     * @param repoToken The address of the repoToken
     * @param idHash The hash of the offer ID
     * @param offerPriceHash The hash of the offer price
     * @param purchaseTokenAmount The amount of purchase tokens being offered
     * @return bytes32[] An array of offer IDs for the submitted offers
     *
     * @dev This function validates the underlying repoToken, checks concentration limits, ensures the auction is open,
     * and rebalances liquidity to support the offer submission. It handles both new offers and edits to existing offers.    
     */
    function submitAuctionOffer(
        address termAuction,
        address repoToken,
        bytes32 idHash,
        bytes32 offerPriceHash,
        uint256 purchaseTokenAmount
    )
        external
        whenNotPaused
        nonReentrant
        onlyManagement
        returns (bytes32[] memory offerIds)
    {
        require(purchaseTokenAmount > 0, "Purchase token amount must be greater than zero");

        // Verify that the term auction is valid and deployed by term
        if (!termController.isTermDeployed(termAuction)) {
            revert InvalidTermAuction(termAuction);
        }

        ITermAuction auction = ITermAuction(termAuction);
        require(auction.termRepoId() == ITermRepoToken(repoToken).termRepoId(), "repoToken does not match term repo ID");

        // Validate purchase token, min collateral ratio and insert the repoToken if necessary
        repoTokenListData.validateRepoToken(
            ITermRepoToken(repoToken),
            termController,
            address(asset)
        );

        _validateRepoTokenConcentration(repoToken, purchaseTokenAmount, 0);

        // Prepare and submit the offer
        ITermAuctionOfferLocker offerLocker = ITermAuctionOfferLocker(
            auction.termAuctionOfferLocker()
        );
        require(
            block.timestamp > offerLocker.auctionStartTime() ||
                block.timestamp < auction.auctionEndTime(),
            "Auction not open"
        );

        // Sweep assets, redeem matured repoTokens and ensure liquid balances up to date
        _sweepAssetAndRedeemRepoTokens(0);

        // Retrieve the total liquid balance
        uint256 liquidBalance = _totalLiquidBalance(address(this));

        uint256 newOfferAmount = purchaseTokenAmount;
        bytes32 offerId = _generateOfferId(idHash, address(offerLocker));
        uint256 currentOfferAmount = termAuctionListData
            .offers[offerId]
            .offerAmount;

        // Handle adjustments if editing an existing offer
        if (newOfferAmount > currentOfferAmount) {
            // increasing offer amount
            uint256 offerDebit;
            unchecked {
                // checked above
                offerDebit = newOfferAmount - currentOfferAmount;
            }
            if (liquidBalance < offerDebit) {
                revert InsufficientLiquidBalance(liquidBalance, offerDebit);
            }
            uint256 newLiquidBalance = liquidBalance - offerDebit;
            if (newLiquidBalance < liquidityReserveRatio) {
                revert BalanceBelowliquidityReserveRatio();
            }
            _validateWeightedMaturity(
                repoToken,
                newOfferAmount,
                newLiquidBalance
            );
        } else if (currentOfferAmount > newOfferAmount) {
            // decreasing offer amount
            uint256 offerCredit;
            unchecked {
                offerCredit = currentOfferAmount - newOfferAmount;
            }
            uint256 newLiquidBalance = liquidBalance + offerCredit;
            if (newLiquidBalance < liquidityReserveRatio) {
                revert BalanceBelowliquidityReserveRatio();
            }
            _validateWeightedMaturity(
                repoToken,
                newOfferAmount,
                newLiquidBalance
            );
        } else {
            // no change in offer amount, do nothing
        }

        // Submit the offer and lock it in the auction
        ITermAuctionOfferLocker.TermAuctionOfferSubmission memory offer;
        offer.id = currentOfferAmount > 0 ? offerId : idHash;
        offer.offeror = address(this);
        offer.offerPriceHash = offerPriceHash;
        offer.amount = purchaseTokenAmount;
        offer.purchaseToken = address(asset);

        offerIds = _submitOffer(
            auction,
            offerLocker,
            offer,
            repoToken,
            newOfferAmount,
            currentOfferAmount
        );
    }

    /**
     * @dev Submits an offer to a term auction and locks it using the offer locker.
     * @param auction The term auction contract
     * @param offerLocker The offer locker contract
     * @param offer The offer details
     * @param repoToken The address of the repoToken
     * @param newOfferAmount The amount of the new offer
     * @param currentOfferAmount The amount of the current offer, if it exists
     * @return bytes32[] An array of offer IDs for the submitted offers
     */
    function _submitOffer(
        ITermAuction auction,
        ITermAuctionOfferLocker offerLocker,
        ITermAuctionOfferLocker.TermAuctionOfferSubmission memory offer,
        address repoToken,
        uint256 newOfferAmount,
        uint256 currentOfferAmount
    ) private returns (bytes32[] memory offerIds) {
        // Retrieve the repo servicer contract
        ITermRepoServicer repoServicer = ITermRepoServicer(
            offerLocker.termRepoServicer()
        );

        // Prepare the offer submission details
        ITermAuctionOfferLocker.TermAuctionOfferSubmission[]
            memory offerSubmissions = new ITermAuctionOfferLocker.TermAuctionOfferSubmission[](
                1
            );
        offerSubmissions[0] = offer;

        // Handle additional asset withdrawal if the new offer amount is greater than the current amount
        if (newOfferAmount > currentOfferAmount) {
            uint256 offerDebit;
            unchecked {
                // checked above
                offerDebit = newOfferAmount - currentOfferAmount;
            }
            _withdrawAsset(offerDebit);
            IERC20(asset).safeApprove(
                address(repoServicer.termRepoLocker()),
                offerDebit
            );
        }

        // Submit the offer and get the offer IDs
        offerIds = offerLocker.lockOffers(offerSubmissions);

        require(offerIds.length > 0, "No offer IDs returned");

        // Update the pending offers list
        if (currentOfferAmount == 0) {
            // new offer
            termAuctionListData.insertPending(
                offerIds[0],
                PendingOffer({
                    repoToken: repoToken,
                    offerAmount: offer.amount,
                    termAuction: auction,
                    offerLocker: offerLocker
                })
            );
        } else {
            // Edit offer, overwrite existing
            termAuctionListData.offers[offerIds[0]] = PendingOffer({
                repoToken: repoToken,
                offerAmount: offer.amount,
                termAuction: auction,
                offerLocker: offerLocker
            });
        }
    }

    /**
     * @dev Removes specified offers from a term auction and performs related cleanup.
     * @param termAuction The address of the term auction from which offers will be deleted.
     * @param offerIds An array of offer IDs to be deleted.
     */
    function deleteAuctionOffers(
        address termAuction,
        bytes32[] calldata offerIds
    ) external onlyManagement {
        // Validate if the term auction is deployed by term
        if (!termController.isTermDeployed(termAuction)) {
            revert InvalidTermAuction(termAuction);
        }

        // Retrieve the auction and offer locker contracts
        ITermAuction auction = ITermAuction(termAuction);
        ITermAuctionOfferLocker offerLocker = ITermAuctionOfferLocker(
            auction.termAuctionOfferLocker()
        );

        // Unlock the specified offers
        offerLocker.unlockOffers(offerIds);

        // Update the term auction list data and remove completed offers
        termAuctionListData.removeCompleted(
            repoTokenListData,
            termController,
            discountRateAdapter,
            address(asset)
        );

        // Sweep any remaining assets and redeem repoTokens
        _sweepAssetAndRedeemRepoTokens(0);
    }

    /**
     * @dev Generate a term offer ID
     * @param id The term offer ID hash
     * @param offerLocker The address of the term offer locker
     * @return The generated term offer ID
     */
    function _generateOfferId(
        bytes32 id,
        address offerLocker
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(id, address(this), offerLocker));
    }

    /**
     * @notice Close the auction
     */
    function auctionClosed() external {
        _sweepAssetAndRedeemRepoTokens(0);
    }

    /*//////////////////////////////////////////////////////////////
                    PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows the sale of a specified amount of a repoToken in exchange for assets.
     * @param repoToken The address of the repoToken to be sold.
     * @param repoTokenAmount The amount of the repoToken to be sold.
     */
    function sellRepoToken(
        address repoToken,
        uint256 repoTokenAmount
    ) external whenNotPaused nonReentrant {
        // Ensure the amount of repoTokens to sell is greater than zero
        require(repoTokenAmount > 0);

        // Validate and insert the repoToken into the list, retrieve auction rate and redemption timestamp
        (uint256 discountRate, uint256 redemptionTimestamp) = repoTokenListData
            .validateAndInsertRepoToken(
                ITermRepoToken(repoToken),
                termController,
                discountRateAdapter,
                address(asset)
            );

        // Sweep assets and redeem repoTokens, if needed
        _sweepAssetAndRedeemRepoTokens(0);

        // Retrieve total liquid balance and ensure it's greater than zero
        uint256 liquidBalance = _totalLiquidBalance(address(this));
        require(liquidBalance > 0);

        // Calculate the repoToken amount in base asset precision
        uint256 repoTokenPrecision = 10 ** ERC20(repoToken).decimals();
        uint256 repoTokenAmountInBaseAssetPrecision = (ITermRepoToken(repoToken)
            .redemptionValue() *
            repoTokenAmount *
            PURCHASE_TOKEN_PRECISION) /
            (repoTokenPrecision * RepoTokenUtils.RATE_PRECISION);

        // Calculate the proceeds from selling the repoToken            
        uint256 proceeds = RepoTokenUtils.calculatePresentValue(
            repoTokenAmountInBaseAssetPrecision,
            PURCHASE_TOKEN_PRECISION,
            redemptionTimestamp,
            discountRate + discountRateMarkup
        );

        // Ensure the liquid balance is sufficient to cover the proceeds
        if (liquidBalance < proceeds) {
            revert InsufficientLiquidBalance(liquidBalance, proceeds);
        }

        // Calculate resulting time to maturity after the sale and ensure it doesn't exceed the threshold
        uint256 resultingTimeToMaturity = _calculateWeightedMaturity(
            repoToken,
            repoTokenAmount,
            liquidBalance - proceeds
        );
        if (resultingTimeToMaturity > timeToMaturityThreshold) {
            revert TimeToMaturityAboveThreshold();
        }

        // Ensure the remaining liquid balance is above the liquidity threshold
        if ((liquidBalance - proceeds) < liquidityReserveRatio) {
            revert BalanceBelowliquidityReserveRatio();
        }

        // Validate resulting repoToken concentration to ensure it meets requirements
        _validateRepoTokenConcentration(
            repoToken,
            repoTokenAmountInBaseAssetPrecision,
            proceeds
        );

        // withdraw from underlying vault
        _withdrawAsset(proceeds);

        // Transfer repoTokens from the sender to the contract
        IERC20(repoToken).safeTransferFrom(
            msg.sender,
            address(this),
            repoTokenAmount
        );

        // Transfer the proceeds in assets to the sender
        IERC20(asset).safeTransfer(msg.sender, proceeds);
    }

    /**
     * @notice Constructor to initialize the Strategy contract
     * @param _asset The address of the asset
     * @param _name The name of the strategy
     * @param _yearnVault The address of the Yearn vault
     * @param _discountRateAdapter The address of the discount rate adapter
     * @param _eventEmitter The address of the event emitter
     */
    constructor(
        address _asset,
        string memory _name,
        address _yearnVault,
        address _discountRateAdapter,
        address _eventEmitter
    ) BaseStrategy(_asset, _name) {
        YEARN_VAULT = IERC4626(_yearnVault);
        TERM_VAULT_EVENT_EMITTER = ITermVaultEvents(_eventEmitter);
        PURCHASE_TOKEN_PRECISION = 10 ** ERC20(asset).decimals();

        discountRateAdapter = ITermDiscountRateAdapter(_discountRateAdapter);

        IERC20(_asset).safeApprove(_yearnVault, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override whenNotPaused {
        _sweepAssetAndRedeemRepoTokens(0);
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override whenNotPaused {
        _sweepAssetAndRedeemRepoTokens(_amount);
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        whenNotPaused
        returns (uint256 _totalAssets)
    {
        // TODO: Implement harvesting logic and accurate accounting EX:
        //
        //      if(!TokenizedStrategy.isShutdown()) {
        //          _claimAndSellRewards();
        //      }
        //      _totalAssets = aToken.balanceOf(address(this)) + asset.balanceOf(address(this));
        //
        _totalAssets = asset.balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies.
     *
     *   EX:
     *       return asset.balanceOf(yieldSource);
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // NOTE: Withdraw limitations such as liquidity constraints should be accounted for HERE
        //  rather than _freeFunds in order to not count them as losses on withdraws.

        // TODO: If desired implement withdraw limit logic and any needed state variables.

        // EX:
        // if(yieldSource.notShutdown()) {
        //    return asset.balanceOf(address(this)) + asset.balanceOf(yieldSource);
        // }
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement deposit limit logic and any needed state variables .
        
        EX:    
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            return totalAssets >= depositLimit ? 0 : depositLimit - totalAssets;
    }
    */

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * This will have no effect on PPS of the strategy till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    function _tend(uint256 _totalIdle) internal override {}
    */

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    function _tendTrigger() internal view override returns (bool) {}
    */

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
    function _emergencyWithdraw(uint256 _amount) internal override {
        TODO: If desired implement simple logic to free deployed funds.

        EX:
            _amount = min(_amount, aToken.balanceOf(address(this)));
            _freeFunds(_amount);
    }

    */
}
