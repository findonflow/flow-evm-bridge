import "FungibleToken"
import "NonFungibleToken"
import "FlowToken"

import "EVM"

import "FlowEVMBridgeUtils"
import "IEVMBridgeNFTLocker"
import "FlowEVMBridgeTemplates"

// TODO:
// - [ ] Consider making an interface that is implemented by auxiliary contracts
// - [ ] Decide on bridge-deployed ERC721 & ERC20 symbol conventions
// - [ ] Trace stack and optimize internal interfaces to remove duplicate calls
access(all) contract FlowEVMBridge {

    /// Amount of $FLOW paid to bridge
    access(all) var fee: UFix64
    /// The COA which orchestrates bridge operations in EVM
    access(self) let coa: @EVM.BridgedAccount

    /// Denotes a contract was deployed to the bridge account, could be either FlowEVMBridgeLocker or FlowEVMBridgedAsset
    access(all) event BridgeLockerContractDeployed(type: Type, name: String, evmContractAddress: EVM.EVMAddress)
    access(all) event BridgeDefiningContractDeployed(type: Type, name: String, evmContractAddress: EVM.EVMAddress)

    /* --- Public NFT Handling --- */

    /// Public entrypoint to bridge NFTs from Flow to EVM - cross-account bridging supported
    ///
    /// @param token: The NFT to be bridged
    /// @param to: The NFT recipient in FlowEVM
    /// @param tollFee: The fee paid for bridging
    ///
    access(all) fun bridgeNFTToEVM(token: @{NonFungibleToken.NFT}, to: EVM.EVMAddress, tollFee: @FlowToken.Vault) {
        pre {
            tollFee.balance >= self.fee: "Insufficient fee paid"
            token.isInstance(Type<@{FungibleToken.Vault}>()) == false: "Mixed asset types are not yet supported"
        }
        if FlowEVMBridgeUtils.isFlowNative(asset: &token) {
            self.bridgeFlowNativeNFTToEVM(token: <-token, to: to, tollFee: <-tollFee)
        } else {
            // TODO: EVM-native NFT path
            // self.bridgeEVMNativeNFTToEVM(token: <-token, to: to, tollFee: <-tollFee)
            destroy <- token
            destroy <- tollFee
        }
    }

    /// Public entrypoint to bridge NFTs from EVM to Flow
    ///
    /// @param caller: The caller executing the bridge - must be passed to check EVM state pre- & post-call in scope
    /// @param calldata: Caller-provided approve() call, enabling contract COA to operate on NFT in EVM contract
    /// @param id: The NFT ID to bridged
    /// @param evmContractAddress: Address of the EVM address defining the NFT being bridged - also call target
    /// @param tollFee: The fee paid for bridging
    ///
    access(all) fun bridgeNFTFromEVM(
        caller: &EVM.BridgedAccount,
        calldata: [UInt8],
        id: UInt256,
        evmContractAddress: EVM.EVMAddress,
        tollFee: @FlowToken.Vault
    ): @{NonFungibleToken.NFT} {
        pre {
            tollFee.balance >= self.fee: "Insufficient fee paid"
        }
        if FlowEVMBridgeUtils.isEVMNative(evmContractAddress: evmContractAddress) {
            // TODO: EVM-native NFT path
        } else {
            return <- self.bridgeFlowNativeNFTFromEVM(
                caller: caller,
                calldata: calldata,
                id: id,
                evmContractAddress: evmContractAddress,
                tollFee: <-tollFee
            )
        }
        panic("Could not route bridge request for the requested NFT")
    }

    /* --- Public FT Handling --- */

    /// Public entrypoint to bridge NFTs from Flow to EVM - cross-account bridging supported
    ///
    /// @param vault: The FungibleToken Vault to be bridged
    /// @param to: The recipient of tokens in FlowEVM
    /// @param tollFee: The fee paid for bridging
    ///
    // access(all) fun bridgeTokensToEVM(vault: @{FungibleToken.Vault}, to: EVM.EVMAddress, tollFee: @FlowToken.Vault) {
    //     pre {
    //         tollFee.balance >= self.fee: "Insufficient fee paid"
    //         vault.isInstance(of: Type<&{NonFungibleToken.NFT}>) == false: "Mixed asset types are not yet supported"
    //     }
    //     // Handle based on whether Flow- or EVM-native & passthrough to internal method
    // }

    /// Public entrypoint to bridge fungible tokens from EVM to Flow
    ///
    /// @param caller: The caller executing the bridge - must be passed to check EVM state pre- & post-call in scope
    /// @param calldata: Caller-provided approve() call, enabling contract COA to operate on tokens in EVM contract
    /// @param amount: The amount of tokens to bridge
    /// @param evmContractAddress: Address of the EVM address defining the tokens being bridged, also call target
    /// @param tollFee: The fee paid for bridging
    ///
    // access(all) fun bridgeTokensFromEVM(
    //     caller: auth(Callable) &BridgedAccount,
    //     calldata: [UInt8],
    //     amount: UFix64,
    //     evmContractAddress: EVM.EVMAddress,
    //     tollFee: @FlowToken.Vault
    // ): @{FungibleToken.Vault} {
    //     pre {
    //         tollFee.balance >= self.fee: "Insufficient fee paid"
    //         FlowEVMBridgeUtils.isEVMToken(evmContractAddress: evmContractAddress): "Unsupported asset type"
    //         FlowEVMBridgeUtils.hasSufficientBalance(amount: amount, owner: caller, evmContractAddress: evmContractAddress):
    //             "Caller does not have sufficient funds to bridge requested amount"
    //     }
    // }

    /* --- Public Getters --- */

    /// Returns the bridge contract's COA EVMAddress
    access(all) fun getBridgeCOAEVMAddress(): EVM.EVMAddress {
        return self.coa.address()
    }
    /// Retrieves the EVM address of the contract related to the bridge contract-defined asset
    /// Useful for bridging flow-native assets back from EVM
    // access(all) fun getAssetEVMContractAddress(type: Type): EVM.EVMAddress? {

    // }
    /// Retrieves the Flow address associated with the asset defined at the provided EVM address if it's defined
    /// in a bridge-deployed contract
    // access(all) fun getAssetFlowContractAddress(evmAddress: EVM.EVMAddress): Address?

    /* --- Internal Helpers --- */

    // Flow-native NFTs - lock & unlock

    /// Handles bridging Flow-native NFTs to EVM - locks NFT in designated Flow locker contract & mints in EVM
    /// Within scope, locker contract is deployed if needed & passing on call to said contract
    access(self) fun bridgeFlowNativeNFTToEVM(token: @{NonFungibleToken.NFT}, to: EVM.EVMAddress, tollFee: @FlowToken.Vault) {
        let lockerContractName: String = FlowEVMBridgeUtils.deriveLockerContractName(fromType: token.getType()) ??
            panic("Could not derive locker contract name for token type: ".concat(token.getType().identifier))
        if self.account.contracts.borrow<&IEVMBridgeNFTLocker>(name: lockerContractName) == nil {
            self.deployLockerContract(forAsset: &token)
        }
        let lockerContract: &IEVMBridgeNFTLocker = self.account.contracts.borrow<&IEVMBridgeNFTLocker>(name: lockerContractName)
            ?? panic("Problem locating Locker contract for token type: ".concat(token.getType().identifier))
        lockerContract.bridgeToEVM(token: <-token, to: to, tollFee: <-tollFee)
    }
    /// Handles bridging Flow-native NFTs from EVM - unlocks NFT from designated Flow locker contract & burns in EVM
    /// Within scope, locker contract is deployed if needed & passing on call to said contract
    // TODO: Update with Callable (or similar) entitlement on COA
    access(self) fun bridgeFlowNativeNFTFromEVM(
        caller: &EVM.BridgedAccount,
        calldata: [UInt8],
        id: UInt256,
        evmContractAddress: EVM.EVMAddress,
        tollFee: @FlowToken.Vault
    ): @{NonFungibleToken.NFT} {
        let response: [String] = self.call(
            signature: "getFlowAssetIdentifier()(string)",
            targetEVMAddress: evmContractAddress,
            args: [],
            gasLimit: 60000,
            value: 0.0
        ) as! [String]
        let lockedType = CompositeType(response[0]) ?? panic("Invalid identifier returned from EVM contract")
        let lockerContractName: String = FlowEVMBridgeUtils.deriveLockerContractName(fromType: lockedType) ??
            panic("Could not derive locker contract name for token type: ".concat(lockedType.identifier))
        let lockerContract: &IEVMBridgeNFTLocker = self.account.contracts.borrow<&IEVMBridgeNFTLocker>(name: lockerContractName)
            ?? panic("Problem configuring Locker contract for token type: ".concat(lockedType.identifier))
        return <- lockerContract.bridgeFromEVM(
            caller: caller,
            calldata: calldata,
            id: id,
            evmContractAddress: evmContractAddress,
            tollFee: <-tollFee
        )
    }

    // EVM-native NFTs - mint & burn

    /// Handles bridging EVM-native NFTs to EVM - burns NFT in defining Flow contract & transfers in EVM
    /// Within scope, defining contract is deployed if needed & passing on call to said contract
    // access(self) fun bridgeEVMNativeNFTToEVM(token: @{NonFungibleToken.NFT}, to: EVM.EVMAddress, tollFee: @FlowToken.Vault)
    /// Handles bridging EVM-native NFTs to EVM - mints NFT in defining Flow contract & transfers in EVM
    /// Within scope, defining contract is deployed if needed & passing on call to said contract
    // access(self) fun bridgeEVMNativeNFTFromEVM(
    //     caller: auth(Callable) &BridgedAccount,
    //     calldata: [UInt8],
    //     id: UInt256,
    //     evmContractAddress: EVM.EVMAddress
    //     tollFee: @FlowToken.Vault
    // ): @{NonFungibleToken.NFT}

    // Flow-native FTs - lock & unlock

    /// Handles bridging Flow-native assets to EVM - locks Vault in designated Flow locker contract & mints in EVM
    /// Within scope, locker contract is deployed if needed
    // access(self) fun bridgeFlowNativeTokensToEVM(vault: @{FungibleToken.Vault}, to: EVM.EVMAddress, tollFee: @FlowToken.Vault)
    /// Handles bridging Flow-native assets from EVM - unlocks Vault from designated Flow locker contract & burns in EVM
    /// Within scope, locker contract is deployed if needed
    // access(self) fun bridgeFlowNativeTokensFromEVM(
    //     caller: auth(Callable) &BridgedAccount,
    //     calldata: [UInt8],
    //     amount: UFix64,
    //     evmContractAddress: EVM.EVMAddress,
    //     tollFee: @FlowToken.Vault
    // ): @{FungibleToken.Vault}

    // EVM-native FTs - mint & burn

    /// Handles bridging EVM-native assets to EVM - burns Vault in defining Flow contract & transfers in EVM
    /// Within scope, defining contract is deployed if needed
    // access(self) fun bridgeEVMNativeTokensToEVM(vault: @{FungibleToken.Vault}, to: EVM.EVMAddress, tollFee: @FlowToken.Vault)
    /// Handles bridging EVM-native assets from EVM - mints Vault from defining Flow contract & transfers in EVM
    /// Within scope, defining contract is deployed if needed
    // access(self) fun bridgeEVMNativeTokensFromEVM(
    //     caller: auth(Callable) &BridgedAccount,
    //     calldata: [UInt8],
    //     amount: UFix64,
    //     evmContractAddress: EVM.EVMAddress,
    //     tollFee: @FlowToken.Vault
    // ): @{FungibleToken.Vault}
    
    /// Helper for deploying templated Locker contract supporting Flow-native asset bridging to EVM
    /// Deploys either NFT or FT locker depending on the asset type
    access(self) fun deployLockerContract(forAsset: &AnyResource) {
        let code: [UInt8] = FlowEVMBridgeTemplates.getLockerContractCode(forType: forAsset.getType())
            ?? panic("Could not retrieve code for given asset type: ".concat(forAsset.getType().identifier))
        let name: String = FlowEVMBridgeUtils.deriveLockerContractName(fromType: forAsset.getType())
            ?? panic("Could not derive locker contract name for token type: ".concat(forAsset.getType().identifier))

        let assetType: Type = forAsset.getType()
        let contractAddress: Address = FlowEVMBridgeUtils.getContractAddress(fromType: assetType)
            ?? panic("Could not derive locker contract address for token type: ".concat(assetType.identifier))
        let evmContractAddress: EVM.EVMAddress = self.deployEVMContract(forAssetType: assetType)

        self.account.contracts.add(name: name, code: code, assetType, contractAddress, evmContractAddress)        
    }
    /// Helper for deploying templated defining contract supporting EVM-native asset bridging to Flow
    /// Deploys either NFT or FT contract depending on the provided type
    // access(self) fun deployDefiningContract(type: Type) {
    //     // TODO
    // }

    access(self) fun deployEVMContract(forAssetType: Type): EVM.EVMAddress {
        if forAssetType.isSubtype(of: Type<@{NonFungibleToken.NFT}>()) {
            return self.deployERC721(forAssetType)
        } else if forAssetType.isSubtype(of: Type<@{FungibleToken.Vault}>()) {
            // TODO
            // return self.deployERC20(name: forAssetType.identifier)
        }
        panic("Unsupported asset type: ".concat(forAssetType.identifier))
    }

    access(self) fun deployERC721(_ forNFTType: Type): EVM.EVMAddress {
        let name: String = FlowEVMBridgeUtils.deriveLockerContractName(fromType: forNFTType)
            ?? panic("Could not derive locker contract name for token type: ".concat(forNFTType.identifier))
        let identifier: String = forNFTType.identifier
        let cadenceAddressStr: String = FlowEVMBridgeUtils.getContractAddress(fromType: forNFTType)?.toString()
            ?? panic("Could not derive contract address for token type: ".concat(identifier))

        let response = self.call(
            signature: "deployERC721(string,string,string,string)(address)",
            targetEVMAddress: self.coa.address(),
            args: [name, "BRDG", cadenceAddressStr, identifier],
            gasLimit: 60000,
            value: 0.0
        ) as! [EVM.EVMAddress]
        return response[0]
    }

    /// Enables other bridge contracts to orchestrate bridge operations from contract-owned COA
    access(account) fun borrowCOA(): &EVM.BridgedAccount {
        return &self.coa as &EVM.BridgedAccount
    }

    access(self) fun call(
        signature: String,
        targetEVMAddress: EVM.EVMAddress,
        args: [AnyStruct],
        gasLimit: UInt64,
        value: UFix64
    ): [UInt8] {
        let methodID: [UInt8] = FlowEVMBridgeUtils.getFunctionSelector(signature: signature)
            ?? panic("Problem getting function selector for ".concat(signature))
        let calldata: [UInt8] = methodID.concat(EVM.encodeABI(args))
        let response = self.coa.call(
            to: targetEVMAddress,
            data: calldata,
            gasLimit: gasLimit,
            value: EVM.Balance(flow: value)
        )
        return response
    }

    init() {
        self.fee = 0.0
        self.coa <- self.account.storage.load<@EVM.BridgedAccount>(from: /storage/evm)
            ?? panic("No COA found in storage")
    }
}
