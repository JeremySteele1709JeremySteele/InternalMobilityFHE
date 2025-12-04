// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract InternalMobilityFHE is SepoliaConfig {
    struct EncryptedProfile {
        uint256 id;
        euint32 encryptedSkills;
        euint32 encryptedPreferences;
        euint32 encryptedEmployeeId;
        uint256 timestamp;
    }
    
    struct DecryptedProfile {
        string skills;
        string preferences;
        string employeeId;
        bool isMatched;
    }

    uint256 public profileCount;
    mapping(uint256 => EncryptedProfile) public encryptedProfiles;
    mapping(uint256 => DecryptedProfile) public decryptedProfiles;
    
    mapping(string => euint32) private encryptedDepartmentStats;
    string[] private departmentList;
    
    mapping(uint256 => uint256) private requestToProfileId;
    
    event ProfileSubmitted(uint256 indexed id, uint256 timestamp);
    event MatchingRequested(uint256 indexed id);
    event ProfileMatched(uint256 indexed id);
    
    modifier onlyEmployee(uint256 profileId) {
        _;
    }
    
    function submitEncryptedProfile(
        euint32 encryptedSkills,
        euint32 encryptedPreferences,
        euint32 encryptedEmployeeId
    ) public {
        profileCount += 1;
        uint256 newId = profileCount;
        
        encryptedProfiles[newId] = EncryptedProfile({
            id: newId,
            encryptedSkills: encryptedSkills,
            encryptedPreferences: encryptedPreferences,
            encryptedEmployeeId: encryptedEmployeeId,
            timestamp: block.timestamp
        });
        
        decryptedProfiles[newId] = DecryptedProfile({
            skills: "",
            preferences: "",
            employeeId: "",
            isMatched: false
        });
        
        emit ProfileSubmitted(newId, block.timestamp);
    }
    
    function requestProfileMatching(uint256 profileId) public onlyEmployee(profileId) {
        EncryptedProfile storage profile = encryptedProfiles[profileId];
        require(!decryptedProfiles[profileId].isMatched, "Already matched");
        
        bytes32[] memory ciphertexts = new bytes32[](3);
        ciphertexts[0] = FHE.toBytes32(profile.encryptedSkills);
        ciphertexts[1] = FHE.toBytes32(profile.encryptedPreferences);
        ciphertexts[2] = FHE.toBytes32(profile.encryptedEmployeeId);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.matchProfile.selector);
        requestToProfileId[reqId] = profileId;
        
        emit MatchingRequested(profileId);
    }
    
    function matchProfile(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 profileId = requestToProfileId[requestId];
        require(profileId != 0, "Invalid request");
        
        EncryptedProfile storage eProfile = encryptedProfiles[profileId];
        DecryptedProfile storage dProfile = decryptedProfiles[profileId];
        require(!dProfile.isMatched, "Already matched");
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        (string memory skills, string memory preferences, string memory employeeId) = 
            abi.decode(cleartexts, (string, string, string));
        
        dProfile.skills = skills;
        dProfile.preferences = preferences;
        dProfile.employeeId = employeeId;
        dProfile.isMatched = true;
        
        if (FHE.isInitialized(encryptedDepartmentStats[dProfile.preferences]) == false) {
            encryptedDepartmentStats[dProfile.preferences] = FHE.asEuint32(0);
            departmentList.push(dProfile.preferences);
        }
        encryptedDepartmentStats[dProfile.preferences] = FHE.add(
            encryptedDepartmentStats[dProfile.preferences], 
            FHE.asEuint32(1)
        );
        
        emit ProfileMatched(profileId);
    }
    
    function getDecryptedProfile(uint256 profileId) public view returns (
        string memory skills,
        string memory preferences,
        string memory employeeId,
        bool isMatched
    ) {
        DecryptedProfile storage p = decryptedProfiles[profileId];
        return (p.skills, p.preferences, p.employeeId, p.isMatched);
    }
    
    function getEncryptedDepartmentStats(string memory department) public view returns (euint32) {
        return encryptedDepartmentStats[department];
    }
    
    function requestDepartmentStatsDecryption(string memory department) public {
        euint32 stats = encryptedDepartmentStats[department];
        require(FHE.isInitialized(stats), "Department not found");
        
        bytes32[] memory ciphertexts = new bytes32[](1);
        ciphertexts[0] = FHE.toBytes32(stats);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptDepartmentStats.selector);
        requestToProfileId[reqId] = bytes32ToUint(keccak256(abi.encodePacked(department)));
    }
    
    function decryptDepartmentStats(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 departmentHash = requestToProfileId[requestId];
        string memory department = getDepartmentFromHash(departmentHash);
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        uint32 stats = abi.decode(cleartexts, (uint32));
    }
    
    function bytes32ToUint(bytes32 b) private pure returns (uint256) {
        return uint256(b);
    }
    
    function getDepartmentFromHash(uint256 hash) private view returns (string memory) {
        for (uint i = 0; i < departmentList.length; i++) {
            if (bytes32ToUint(keccak256(abi.encodePacked(departmentList[i]))) == hash) {
                return departmentList[i];
            }
        }
        revert("Department not found");
    }
    
    function findPotentialMatches(
        string memory requiredSkills,
        string memory targetDepartment
    ) public view returns (string[] memory matchedEmployees) {
        uint256 count = 0;
        for (uint256 i = 1; i <= profileCount; i++) {
            if (decryptedProfiles[i].isMatched && 
                containsAllSkills(decryptedProfiles[i].skills, requiredSkills) &&
                keccak256(abi.encodePacked(decryptedProfiles[i].preferences)) == keccak256(abi.encodePacked(targetDepartment))) {
                count++;
            }
        }
        
        matchedEmployees = new string[](count);
        uint256 index = 0;
        for (uint256 i = 1; i <= profileCount; i++) {
            if (decryptedProfiles[i].isMatched && 
                containsAllSkills(decryptedProfiles[i].skills, requiredSkills) &&
                keccak256(abi.encodePacked(decryptedProfiles[i].preferences)) == keccak256(abi.encodePacked(targetDepartment))) {
                matchedEmployees[index] = decryptedProfiles[i].employeeId;
                index++;
            }
        }
        return matchedEmployees;
    }
    
    function containsAllSkills(string memory profileSkills, string memory requiredSkills) private pure returns (bool) {
        // Simplified skill matching logic
        // In real implementation, this would properly compare skill sets
        return true;
    }
}