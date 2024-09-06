// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ITermAuction} from "./interfaces/term/ITermAuction.sol";
import {ITermAuctionOfferLocker} from "./interfaces/term/ITermAuctionOfferLocker.sol";
import {ITermRepoToken} from "./interfaces/term/ITermRepoToken.sol";
import {ITermDiscountRateAdapter} from "./interfaces/term/ITermDiscountRateAdapter.sol";
import {RepoTokenList, RepoTokenListData} from "./RepoTokenList.sol";
import {RepoTokenUtils} from "./RepoTokenUtils.sol";

// In-storage representation of an offer object
struct PendingOffer {
    address repoToken;
    uint256 offerAmount;
    ITermAuction termAuction;
    ITermAuctionOfferLocker offerLocker;   
}

// In-memory representation of an offer object
struct PendingOfferMemory {
    bytes32 offerId;
    address repoToken;
    uint256 offerAmount;
    ITermAuction termAuction;
    ITermAuctionOfferLocker offerLocker;   
    bool isRepoTokenSeen;
}

struct TermAuctionListNode {
    bytes32 next;
}

struct TermAuctionListData {
    bytes32 head;
    uint16 size;
    mapping(bytes32 => TermAuctionListNode) nodes;
    mapping(bytes32 => PendingOffer) offers;
}

/*//////////////////////////////////////////////////////////////
                        LIBRARY: TermAuctionList
//////////////////////////////////////////////////////////////*/

library TermAuctionList {
    using RepoTokenList for RepoTokenListData;

    bytes32 public constant NULL_NODE = bytes32(0);    

    /*//////////////////////////////////////////////////////////////
                        PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get the next node in the list
     * @param listData The list data
     * @param current The current node
     * @return The next node
     */
    function _getNext(TermAuctionListData storage listData, bytes32 current) private view returns (bytes32) {
        return listData.nodes[current].next;
    }

    /**
     * @notice Loads all pending offers into an array of `PendingOfferMemory` structs
     * @param listData The list data
     * @return offers An array of structs containing details of all pending offers
     *
     * @dev This function iterates through the list of offers and gathers their details into an array of `PendingOfferMemory` structs.
     * This makes it easier to process and analyze the pending offers.
     */
    function _loadOffers(TermAuctionListData storage listData) private view returns (PendingOfferMemory[] memory offers) {
        uint256 len = _count(listData);
        offers = new PendingOfferMemory[](len);

        uint256 i;
        bytes32 current = listData.head;
        while (current != NULL_NODE) {
            PendingOffer memory currentOffer = listData.offers[current];
            PendingOfferMemory memory newOffer = offers[i];

            newOffer.offerId = current;
            newOffer.repoToken = currentOffer.repoToken;
            newOffer.offerAmount = currentOffer.offerAmount;
            newOffer.termAuction = currentOffer.termAuction;
            newOffer.offerLocker = currentOffer.offerLocker;

            i++;
            current = _getNext(listData, current);
        }
    }

    /**
     * @notice Checks if repo token has been seen before during iteration
     * @param repoTokensSeen The array of repoTokens that have been marked as seen
     * @param repoToken The address of the repoToken to be marked as seen
     *
     * @dev This function iterates through the `offers` array and sets the `isRepoTokenSeen` flag to `true`
     * for the specified `repoToken`. This helps to avoid double-counting or reprocessing the same repoToken.
     */
    function _hasRepoTokenBeenSeen(address[] memory repoTokensSeen, address repoToken) private view returns(bool ) {
        uint256 i;
        while (repoTokensSeen[i] != address(0)) {
            if (repoTokensSeen[i] == repoToken) {
                return true;
            }
            i++;
        }
        return false;
    }

    /**
     * @notice Marks a specific repoToken as seen within offers array
     * @param repoTokensSeen The array of repoTokens that have been marked as seen
     * @param repoToken The address of the repoToken to be marked as seen
     *
     * @dev This function iterates through the `offers` array and sets the `isRepoTokenSeen` flag to `true`
     * for the specified `repoToken`. This helps to avoid double-counting or reprocessing the same repoToken.
     */
    function _markRepoTokenAsSeen(address[] memory repoTokensSeen, address repoToken) private  {
        uint256 i;
        while (repoTokensSeen[i] != address(0)) {
            i++;
        }
        repoTokensSeen[i] = repoToken;
    }

    /**
     * @notice Marks a specific repoToken as seen within an array of `PendingOfferMemory` structs
     * @param offers The array of `PendingOfferMemory` structs representing the pending offers
     * @param repoToken The address of the repoToken to be marked as seen
     *
     * @dev This function iterates through the `offers` array and sets the `isRepoTokenSeen` flag to `true`
     * for the specified `repoToken`. This helps to avoid double-counting or reprocessing the same repoToken.
     */
    function _markRepoTokenAsSeen(PendingOfferMemory[] memory offers, address repoToken) private pure {
        for (uint256 i; i < offers.length; i++) {
            if (repoToken == offers[i].repoToken) {
                offers[i].isRepoTokenSeen = true;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Count the number of nodes in the list
     * @param listData The list data
     * @return count The number of nodes in the list
     */
    function _count(TermAuctionListData storage listData) internal view returns (uint256 count) {
        if (listData.head == NULL_NODE) return 0;
        bytes32 current = listData.head;
        while (current != NULL_NODE) {
            count++;
            current = _getNext(listData, current);
        }
    }

    /**
     * @notice Retrieves an array of offer IDs representing the pending offers
     * @param listData The list data
     * @return offers An array of offer IDs representing the pending offers
     *
     * @dev This function iterates through the list of offers and gathers their IDs into an array of `bytes32`.
     * This makes it easier to process and manage the pending offers.
     */
    function pendingOffers(TermAuctionListData storage listData) internal view returns (bytes32[] memory offers) {
        uint256 count = _count(listData);
        if (count > 0) {
            offers = new bytes32[](count);
            uint256 i;
            bytes32 current = listData.head;
            while (current != NULL_NODE) {
                offers[i++] = current;
                current = _getNext(listData, current);
            } 
        }   
    }

    /**
     * @notice Inserts a new pending offer into the list data
     * @param listData The list data
     * @param offerId The ID of the offer to be inserted
     * @param pendingOffer The `PendingOffer` struct containing details of the offer to be inserted
     *
     * @dev This function inserts a new pending offer at the beginning of the linked list in the `TermAuctionListData` structure.
     * It updates the `next` pointers and the head of the list to ensure the new offer is correctly linked.
     */
    function insertPending(TermAuctionListData storage listData, bytes32 offerId, PendingOffer memory pendingOffer) internal {
        bytes32 current = listData.head;

        if (current != NULL_NODE) {
            listData.nodes[offerId].next = current;
        }

        listData.head = offerId;
        listData.offers[offerId] = pendingOffer;
        ++listData.size;
    }

    /**
     * @notice Removes completed or cancelled offers from the list data and processes the corresponding repoTokens
     * @param listData The list data
     * @param repoTokenListData The repoToken list data
     * @param discountRateAdapter The discount rate adapter
     * @param asset The address of the asset
     *
     * @dev This function iterates through the list of offers and removes those that are completed or cancelled.
     * It processes the corresponding repoTokens by validating and inserting them if necessary. This helps maintain
     * the list by clearing out inactive offers and ensuring repoTokens are correctly processed.
     */
    function removeCompleted(
        TermAuctionListData storage listData, 
        RepoTokenListData storage repoTokenListData,
        ITermDiscountRateAdapter discountRateAdapter,
        address asset
    ) internal {
        // Return if the list is empty
        if (listData.head == NULL_NODE) return;

        bytes32 current = listData.head;
        bytes32 prev = current;
        while (current != NULL_NODE) {
            PendingOffer memory offer = listData.offers[current];
            bytes32 next = _getNext(listData, current);

            uint256 offerAmount = offer.offerLocker.lockedOffer(current).amount;
            bool removeNode;
            bool insertRepoToken;

            if (offer.termAuction.auctionCompleted()) {
                // If auction is completed and closed, mark for removal and prepare to insert repo token
                removeNode = true;
                insertRepoToken = true;
            } else {
                if (offerAmount == 0) {
                    // If offer amount is zero, it indicates the auction was canceled or deleted
                    removeNode = true;
                } else {
                    // Otherwise, do nothing if the offer is still pending
                }

                if (offer.termAuction.auctionCancelledForWithdrawal()) {
                    // If auction was canceled for withdrawal, remove the node and unlock offers manually
                    removeNode = true;                  
                    bytes32[] memory offerIds = new bytes32[](1);
                    offerIds[0] = current;
                    offer.offerLocker.unlockOffers(offerIds); // unlocking offer in this scenario withdraws offer ammount
                }
            }

            if (removeNode) {
                // Update the list to remove the current node
                if (current == listData.head) {
                    listData.head = next;
                }
                
                listData.nodes[prev].next = next;
                delete listData.nodes[current];
                delete listData.offers[current];
                --listData.size;
            }

            if (insertRepoToken) {
                // TODO: do we need to validate termDeployed(repoToken) here?

                // Auction still open => include offerAmount in totalValue 
                // (otherwise locked purchaseToken will be missing from TV)               
                // Auction completed but not closed => include offer.offerAmount in totalValue 
                // because the offerLocker will have already removed the offer. 
                // This applies if the repoToken hasn't been added to the repoTokenList 
                // (only for new auctions, not reopenings).                 
                repoTokenListData.validateAndInsertRepoToken(
                    ITermRepoToken(offer.repoToken), discountRateAdapter, asset
                );
            }

            // Move to the next node
            prev = current;
            current = next;
        }
    }

    /**
     * @notice Calculates the total present value of all relevant offers related to a specified repoToken
     * @param listData The list data
     * @param repoTokenListData The repoToken list data
     * @param discountRateAdapter The discount rate adapter
     * @param purchaseTokenPrecision The precision of the purchase token
     * @param repoTokenToMatch The address of the repoToken to match (optional)
     * @return totalValue The total present value of the offers
     *
     * @dev This function calculates the present value of offers in the list. If `repoTokenToMatch` is provided,
     * it will filter the calculations to include only the specified repoToken. If `repoTokenToMatch` is not provided,
     * it will aggregate the present value of all repoTokens in the list. This provides flexibility for both aggregate
     * and specific token evaluations.     
     */
    function getPresentValue(
        TermAuctionListData storage listData, 
        RepoTokenListData storage repoTokenListData,
        ITermDiscountRateAdapter discountRateAdapter,
        uint256 purchaseTokenPrecision,
        address repoTokenToMatch
    ) internal view returns (uint256 totalValue) {
        // Return 0 if the list is empty
        if (listData.head == NULL_NODE) return 0;

        bytes32 current = listData.head;
        address[] memory repoTokensSeen = new address[](listData.size);
        address repoToken;
        
        while (current != NULL_NODE) {
            repoToken = listData.offers[current].repoToken;
            // Filter by specific repo token if provided, address(0) bypasses this filter
            if (repoTokenToMatch != address(0) && repoToken != repoTokenToMatch) {
                // Not a match, skip
                continue;
            }

            uint256 offerAmount = listData.offers[current].offerLocker.lockedOffer(current).amount;

            // Handle new or unseen repo tokens
            /// @dev offer processed, but auctionClosed not yet called and auction is new so repoToken not on List and wont be picked up
            /// checking repoTokendiscountRates to make sure we are not double counting on re-openings
            if (listData.offers[current].termAuction.auctionCompleted() && repoTokenListData.discountRates[repoToken] == 0) {
                if (!_hasRepoTokenBeenSeen(repoTokensSeen, repoToken)){
                    uint256 repoTokenAmountInBaseAssetPrecision = RepoTokenUtils.getNormalizedRepoTokenAmount(
                        repoToken, 
                        ITermRepoToken(repoToken).balanceOf(address(this)),
                        purchaseTokenPrecision
                    );
                    totalValue += RepoTokenUtils.calculatePresentValue(
                        repoTokenAmountInBaseAssetPrecision, 
                        purchaseTokenPrecision, 
                        RepoTokenList.getRepoTokenMaturity(repoToken), 
                        discountRateAdapter.getDiscountRate(repoToken)
                    );
                }
                _markRepoTokenAsSeen(repoTokensSeen, repoToken);
                
            } else {
                // Add the offer amount to the total value
                totalValue += offerAmount;
            }

            current = _getNext(listData, current);
        }
        
        return totalValue; 
    }

    /**
     * @notice Get cumulative offer data for a specified repoToken
     * @param listData The list data
     * @param repoTokenListData The repoToken list data
     * @param repoToken The address of the repoToken (optional)
     * @param newOfferAmount The new offer amount for the specified repoToken 
     * @param purchaseTokenPrecision The precision of the purchase token
     * @return cumulativeWeightedTimeToMaturity The cumulative weighted time to maturity
     * @return cumulativeOfferAmount The cumulative repoToken amount
     * @return found Whether the specified repoToken was found in the list
     *
     * @dev This function calculates cumulative data for all offers in the list. The `repoToken` and `newOfferAmount`
     * parameters are optional and provide flexibility to include the newOfferAmount for a specified repoToken in the calculation.
     * If `repoToken` is set to `address(0)` or `newOfferAmount` is `0`, the function calculates the cumulative data
     * without adjustments. 
     */
    function getCumulativeOfferData(
        TermAuctionListData storage listData,
        RepoTokenListData storage repoTokenListData,
        address repoToken, 
        uint256 newOfferAmount,
        uint256 purchaseTokenPrecision
    ) internal view returns (uint256 cumulativeWeightedTimeToMaturity, uint256 cumulativeOfferAmount, bool found) {
        // If the list is empty, return 0s and false
        if (listData.head == NULL_NODE) return (0, 0, false);

        // Load pending offers from the list data
        PendingOfferMemory[] memory offers = _loadOffers(listData);

        for (uint256 i; i < offers.length; i++) {
            PendingOfferMemory memory offer = offers[i];

            uint256 offerAmount;
            if (offer.repoToken == repoToken) {
                offerAmount = newOfferAmount;
                found = true;
            } else {
                // Retrieve the current offer amount from the offer locker
                offerAmount = offer.offerLocker.lockedOffer(offer.offerId).amount;

                // Handle new repo tokens or reopening auctions
                /// @dev offer processed, but auctionClosed not yet called and auction is new so repoToken not on List and wont be picked up
                /// checking repoTokendiscountRates to make sure we are not double counting on re-openings
                if (offer.termAuction.auctionCompleted() && repoTokenListData.discountRates[offer.repoToken] == 0) {
                    // use normalized repoToken amount if repoToken is not in the list
                    if (!offer.isRepoTokenSeen) {                    
                        offerAmount = RepoTokenUtils.getNormalizedRepoTokenAmount(
                            offer.repoToken, 
                            ITermRepoToken(offer.repoToken).balanceOf(address(this)),
                            purchaseTokenPrecision
                        );

                        _markRepoTokenAsSeen(offers, offer.repoToken);
                    }
                }
            }

            if (offerAmount > 0) {
                // Calculate weighted time to maturity
                uint256 weightedTimeToMaturity = RepoTokenList.getRepoTokenWeightedTimeToMaturity(
                    offer.repoToken, offerAmount
                );            

                cumulativeWeightedTimeToMaturity += weightedTimeToMaturity;
                cumulativeOfferAmount += offerAmount;
            }
        }
    }
}