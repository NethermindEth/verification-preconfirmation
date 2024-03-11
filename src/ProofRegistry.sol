// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ProofRegistry {
    enum PROOF_STATUS {
        RECEIVED,
        FINALISED
    }

    struct ProofVerificationClaim {
        bool isValid;
        address verifiedBy;
        uint verificationTimestamp;
    }

    struct RewardData {
        uint256 reward;
        // token address(0x0) is considered as ETH
        ERC20 token;
        uint256 finalisationTimestamp;
    }

    uint public immutable CHALLENGE_PERIOD;
    // Only opt-ed Ethereum validators can vote on the verification
    mapping(address => bool) public canVote;
    // proof => (is proof valid, address of the validator that voted, timestamp that they voted)
    // address(0x1) and timestamp = 1, indicate that the proof was verified on-chain
    mapping(bytes => ProofVerificationClaim) public isValidProof;
    // proof => address of validator that voted => (reward for verifying the proof, finalisation timestamp of proof)
    mapping(bytes => mapping(address => RewardData)) public claims;

    constructor(uint challengePeriod) {
        CHALLENGE_PERIOD = challengePeriod;
    }

    // Restaked Ethereum Validators can use this function to update the registry
    function voteValidProof(bytes calldata proof, bool isValid) external {
        address proofVerifier = msg.sender;

        if (canVote[proofVerifier]) {
            isValidProof[proof] = ProofVerificationClaim({
                isValid: isValid,
                verifiedBy: proofVerifier,
                verificationTimestamp: block.timestamp
            });
        }
    }

    function verifyERC20(bytes calldata proof, ERC20 token, uint reward) external payable returns (bool, PROOF_STATUS) {
        if (
            isValidProof[proof].verifiedBy == address(0x0) &&
            isValidProof[proof].verificationTimestamp == 0
        ) {
            IVerifier verifier = getProofVerificationContract(proof);
            bool isValid = verifier.verify(proof);

            isValidProof[proof] = ProofVerificationClaim({
                isValid: isValid,
                verifiedBy: address(0),
                verificationTimestamp: 0
            });

            return (isValid, PROOF_STATUS.FINALISED);
        } else {
            // Escrow the reward in ERC20 token from the prover in the ProofRegistry
            token.transferFrom(msg.sender, address(this), reward);

            ProofVerificationClaim memory proofWitness = isValidProof[proof];
            (bool isValid, address verifiedBy, uint verificationTimestamp) = (
                proofWitness.isValid,
                proofWitness.verifiedBy,
                proofWitness.verificationTimestamp
            );

            if (
                verifiedBy == address(0x1) &&
                verificationTimestamp == 1
            ) {
                return (isValid, PROOF_STATUS.FINALISED);
            } else if (
                block.timestamp >=
                    verificationTimestamp + CHALLENGE_PERIOD
            ) {
                return (isValid, PROOF_STATUS.FINALISED);
            } else {
                claims[proof][verifiedBy] = RewardData({
                    reward: reward,
                    token: token,
                    finalisationTimestamp: verificationTimestamp +
                        CHALLENGE_PERIOD
                });
                return (isValid, PROOF_STATUS.RECEIVED);
            }
        }
    }

    function verify(
        bytes calldata proof
    ) external payable returns (bool, PROOF_STATUS) {
        uint reward = msg.value;
        if (
            isValidProof[proof].verifiedBy == address(0x0) &&
            isValidProof[proof].verificationTimestamp == 0
        ) {
            // return the bid since no record for the proof in the registry
            payable(msg.sender).transfer(reward);

            IVerifier verifier = getProofVerificationContract(proof);
            bool isValid = verifier.verify(proof);

            isValidProof[proof] = ProofVerificationClaim({
                isValid: isValid,
                verifiedBy: address(0),
                verificationTimestamp: 0
            });

            return (isValid, PROOF_STATUS.FINALISED);
        } else {
            ProofVerificationClaim memory proofWitness = isValidProof[proof];
            (bool isValid, address verifiedBy, uint verificationTimestamp) = (
                proofWitness.isValid,
                proofWitness.verifiedBy,
                proofWitness.verificationTimestamp
            );

            if (
                verifiedBy == address(0x1) &&
                verificationTimestamp == 1
            ) {
                return (isValid, PROOF_STATUS.FINALISED);
            } else if (
                block.timestamp >=
                    verificationTimestamp + CHALLENGE_PERIOD
            ) {
                return (isValid, PROOF_STATUS.FINALISED);
            } else {
                claims[proof][verifiedBy] = RewardData({
                    reward: reward,
                    token: ERC20(address(0x0)),
                    finalisationTimestamp: verificationTimestamp +
                        CHALLENGE_PERIOD
                });
                return (isValid, PROOF_STATUS.RECEIVED);
            }
        }
    }

    function challenge(bytes calldata proof) external {
        ProofVerificationClaim memory proofWitness = isValidProof[proof];
        (
            bool originalProofVote,
            address originalVerifier,
            uint originalVerificationTimestamp
        ) = (
                proofWitness.isValid,
                proofWitness.verifiedBy,
                proofWitness.verificationTimestamp
            );

        if (
            originalVerifier == address(0x0) && originalVerificationTimestamp == 0
        ) {
            revert("No past vote");
        }

        if (
            originalVerifier == address(0x1) && originalVerificationTimestamp == 1
        ) {
            revert("Proof was verified on-chain, cannot be challenged");
        }

        if (
            block.timestamp > CHALLENGE_PERIOD + originalVerificationTimestamp
        ) {
            revert("Challenge period past");
        }

        IVerifier verifier = getProofVerificationContract(proof);

        bool challengerVote = verifier.verify(proof);
        address challengerAddress = msg.sender;

        (uint bid, ERC20 token, uint finalisationTimestamp) = (
            claims[proof][originalVerifier].reward,
            claims[proof][originalVerifier].token,
            claims[proof][originalVerifier].finalisationTimestamp
        );

        if (challengerVote != originalProofVote) {
            // Original proposer lied about the verification of the proof
            isValidProof[proof] = ProofVerificationClaim({
                isValid: challengerVote,
                verifiedBy: address(0),
                verificationTimestamp: 0
            });
            // Pay the challenger
            if (token != ERC20(address(0x0))) {
                token.transfer(challengerAddress, bid);
            } else {
                payable(challengerAddress).transfer(bid);
            }
            // Penalise the original verifier
            slash(originalVerifier);
        }
    }

    function claimReward(bytes calldata proof) external {
        if (
            claims[proof][msg.sender].finalisationTimestamp == 0 &&
            claims[proof][msg.sender].reward == 0
        ) {
            revert("not a valid claim");
        }

        (uint bid, ERC20 token, uint finalisationTimestamp) = (
            claims[proof][msg.sender].reward,
            claims[proof][msg.sender].token,
            claims[proof][msg.sender].finalisationTimestamp
        );

        if (block.timestamp < finalisationTimestamp) {
            revert("proof not finalised");
        }

        // collect reward for verifying proof off-chain
        if (token != ERC20(address(0x0))) {
            token.transfer(msg.sender, bid);
        } else {
          payable(msg.sender).transfer(bid);
        }
    }

    function getProofVerificationContract(
        bytes calldata proof
    ) internal pure returns (IVerifier) {
        // returns the contract address of a verifier contract based on the type of proof
        return IVerifier(address(0x0));
    }

    function slash(address maliciousProposer) internal {
        // penalises the maliciousProposer and evicts them from the precompile service
        // eigenlayer slashing
    }
}

interface IVerifier {
    function verify(bytes calldata proof) external returns (bool);
}