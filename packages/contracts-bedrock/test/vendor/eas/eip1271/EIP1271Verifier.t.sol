// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { Test } from "forge-std/Test.sol";
import { EIP1271Verifier, InvalidSignature } from "src/vendor/eas/eip1271/EIP1271Verifier.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { DeadlineExpired } from "src/vendor/eas/Common.sol";
import { 
    AttestationRequestData,
    DelegatedAttestationRequest,
    Signature,
    IEAS 
} from "src/vendor/eas/IEAS.sol";

contract TestEIP1271Verifier is EIP1271Verifier {
    constructor(string memory name) EIP1271Verifier(name, "1.0.0") {}

    function verifyAttest(DelegatedAttestationRequest calldata request) external {
        _verifyAttest(request);
    }

    function time() public view returns (uint64) {
        return _time();
    }
}

contract MockEIP1271Signer {
    mapping(bytes32 => bytes) public mockSignatures;

    function mockSignature(bytes32 hash, bytes memory signature) external {
        mockSignatures[hash] = signature;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (keccak256(mockSignatures[hash]) == keccak256(signature)) {
            return 0x1626ba7e; // Magic value for EIP-1271
        }
        return 0xffffffff;
    }
}

contract EIP1271VerifierTest is Test {
    error InvalidNonce();
    event NonceIncreased(uint256 oldNonce, uint256 newNonce);
    
    TestEIP1271Verifier public verifier;
    MockEIP1271Signer public mockSigner;
    address public recipient;
    uint256 public signerPrivateKey;
    address public signer;

    bytes32 constant ZERO_BYTES32 = bytes32(0);
    uint64 constant NO_EXPIRATION = 0;

    // Match the exact ATTEST_TYPEHASH from the contract
    bytes32 private constant ATTEST_TYPEHASH = 0xfeb2925a02bae3dae48d424a0437a2b6ac939aa9230ddc55a1a76f065d988076;

    function setUp() public {
        verifier = new TestEIP1271Verifier("EAS");
        mockSigner = new MockEIP1271Signer();
        recipient = makeAddr("recipient");
        
        // Create a signer
        signerPrivateKey = 0xA11CE;
        signer = vm.addr(signerPrivateKey);
    }

    function testInitialState() public view {
        assertEq(verifier.getName(), "EAS");
        assertEq(verifier.getNonce(signer), 0);
    }

    function testIncreaseNonce() public {
        vm.startPrank(signer);
        
        uint256 newNonce = 100;
        vm.expectEmit(true, true, true, true);
        emit NonceIncreased(0, newNonce);
        verifier.increaseNonce(newNonce);
        
        assertEq(verifier.getNonce(signer), newNonce);
        
        // Should revert when trying to decrease nonce
        vm.expectRevert(abi.encodeWithSelector(InvalidNonce.selector));
        verifier.increaseNonce(newNonce - 1);
        
        vm.stopPrank();
    }

    function testDeadlineExpired() public {
        // Set block timestamp
        vm.warp(1000);
        
        // Create attestation request with expired deadline
        DelegatedAttestationRequest memory request = DelegatedAttestationRequest({
            schema: ZERO_BYTES32,
            data: AttestationRequestData({
                recipient: recipient,
                expirationTime: NO_EXPIRATION,
                revocable: true,
                refUID: ZERO_BYTES32,
                data: new bytes(0),
                value: 1000
            }),
            deadline: 999, // Expired
            attester: signer,
            signature: Signature({
                v: 27,
                r: bytes32(0),
                s: bytes32(0)
            })
        });

        vm.expectRevert(abi.encodeWithSelector(DeadlineExpired.selector));
        verifier.verifyAttest(request);
    }

    function testSignatureVerification() public {
        bytes32 schemaId = ZERO_BYTES32;
        uint64 deadline = uint64(block.timestamp + 3600);
        
        DelegatedAttestationRequest memory request = DelegatedAttestationRequest({
            schema: schemaId,
            data: AttestationRequestData({
                recipient: recipient,
                expirationTime: NO_EXPIRATION,
                revocable: true,
                refUID: ZERO_BYTES32,
                data: new bytes(0),
                value: 0
            }),
            deadline: deadline,
            attester: signer,
            signature: Signature({
                v: 27,
                r: bytes32(0),
                s: bytes32(0)
            })
        });

        // Should fail with invalid signature
        vm.expectRevert(abi.encodeWithSelector(InvalidSignature.selector));
        verifier.verifyAttest(request);

        // Create valid signature
        bytes32 hash = _hashTypedDataV4(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, hash);
        request.signature = Signature(v, r, s);

        // Should pass with valid signature
        verifier.verifyAttest(request);
    }

    function testMultipleAttestationDelegation() public {
        bytes32 schemaId = ZERO_BYTES32;
        uint64 deadline = uint64(block.timestamp + 3600);
        
        DelegatedAttestationRequest[] memory requests = new DelegatedAttestationRequest[](2);
        
        // Create valid signatures with incrementing nonces
        for(uint i = 0; i < 2; i++) {
            requests[i] = DelegatedAttestationRequest({
                schema: schemaId,
                data: AttestationRequestData({
                    recipient: recipient,
                    expirationTime: NO_EXPIRATION,
                    revocable: true,
                    refUID: ZERO_BYTES32,
                    data: new bytes(0),
                    value: 0
                }),
                deadline: deadline,
                attester: signer,
                signature: Signature({
                    v: 27,
                    r: bytes32(0),
                    s: bytes32(0)
                })
            });

            // Get hash with current nonce
            bytes32 hash = _hashTypedDataV4(requests[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, hash);
            requests[i].signature = Signature(v, r, s);

            // Verify and increment nonce
            verifier.verifyAttest(requests[i]);
        }
    }

    function testComplexNonceScenarios() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Test nonce independence between users
        vm.prank(user1);
        verifier.increaseNonce(100);
        
        vm.prank(user2);
        verifier.increaseNonce(200);

        assertEq(verifier.getNonce(user1), 100);
        assertEq(verifier.getNonce(user2), 200);

        // Test sequential nonce increases
        vm.startPrank(user1);
        verifier.increaseNonce(101);
        verifier.increaseNonce(102);
        verifier.increaseNonce(103);
        vm.stopPrank();

        assertEq(verifier.getNonce(user1), 103);
    }

    function testEIP1271SignatureValidation() public {
        MockEIP1271Signer eip1271Contract = new MockEIP1271Signer();
        
        bytes32 schemaId = ZERO_BYTES32;
        uint64 deadline = uint64(block.timestamp + 3600);
        
        DelegatedAttestationRequest memory request = DelegatedAttestationRequest({
            schema: schemaId,
            data: AttestationRequestData({
                recipient: recipient,
                expirationTime: NO_EXPIRATION,
                revocable: true,
                refUID: ZERO_BYTES32,
                data: new bytes(0),
                value: 0
            }),
            deadline: deadline,
            attester: address(eip1271Contract),
            signature: Signature({
                v: 27,
                r: bytes32(0),
                s: bytes32(0)
            })
        });

        // Mock valid signature
        bytes32 hash = _hashTypedDataV4(request);
        bytes memory signature = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));
        eip1271Contract.mockSignature(hash, signature);

        // Update request with mocked signature
        request.signature = Signature({
            v: 27,
            r: bytes32(uint256(1)),
            s: bytes32(uint256(2))
        });

        // Should pass with valid EIP1271 signature
        verifier.verifyAttest(request);
    }

    function _hashTypedDataV4(DelegatedAttestationRequest memory request) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                ATTEST_TYPEHASH,
                request.attester,
                request.schema,
                request.data.recipient,
                request.data.expirationTime,
                request.data.revocable,
                request.data.refUID,
                keccak256(request.data.data),
                request.data.value,
                verifier.getNonce(request.attester),
                request.deadline
            )
        );

        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                verifier.getDomainSeparator(),
                structHash
            )
        );
    }
}
