import "FlowToken"
import "FungibleToken"
import "NonFungibleToken"

access(all)
contract EVM {

    access(all) entitlement Bridge

    /// EVMAddress is an EVM-compatible address
    access(all)
    struct EVMAddress {

        /// Bytes of the address
        access(all)
        let bytes: [UInt8; 20]

        /// Constructs a new EVM address from the given byte representation
        init(bytes: [UInt8; 20]) {
            self.bytes = bytes
        }

        /// Deposits the given vault into the EVM account with the given address
        access(all)
        fun deposit(from: @FlowToken.Vault) {
            InternalEVM.deposit(
                from: <-from,
                to: self.bytes
            )
        }

        /// Balance of the address
        access(all)
        fun balance(): Balance {
            let balance = InternalEVM.balance(
                address: self.bytes
            )

            return Balance(flow: balance)
        }
    }

    access(all)
    struct Balance {

        /// The balance in FLOW
        access(all)
        let flow: UFix64

        /// Constructs a new balance, given the balance in FLOW
        init(flow: UFix64) {
            self.flow = flow
        }

        // TODO:
        // /// Returns the balance in terms of atto-FLOW.
        // /// Atto-FLOW is the smallest denomination of FLOW inside EVM
        // access(all)
        // fun toAttoFlow(): UInt64
    }

    access(all)
    resource BridgedAccount {

        access(self)
        let addressBytes: [UInt8; 20]

        init(addressBytes: [UInt8; 20]) {
           self.addressBytes = addressBytes
        }

        /// The EVM address of the bridged account
        access(all)
        fun address(): EVMAddress {
            // Always create a new EVMAddress instance
            return EVMAddress(bytes: self.addressBytes)
        }

        /// Get balance of the bridged account
        access(all)
        fun balance(): Balance {
            return self.address().balance()
        }

        /// Deposits the given vault into the bridged account's balance
        access(all)
        fun deposit(from: @FlowToken.Vault) {
            self.address().deposit(from: <-from)
        }

        /// Withdraws the balance from the bridged account's balance
        access(all)
        fun withdraw(balance: Balance): @FlowToken.Vault {
            let vault <- InternalEVM.withdraw(
                from: self.addressBytes,
                amount: balance.flow
            ) as! @FlowToken.Vault
            return <-vault
        }

        /// Deploys a contract to the EVM environment.
        /// Returns the address of the newly deployed contract
        access(all)
        fun deploy(
            code: [UInt8],
            gasLimit: UInt64,
            value: Balance
        ): EVMAddress {
            let addressBytes = InternalEVM.deploy(
                from: self.addressBytes,
                code: code,
                gasLimit: gasLimit,
                value: value.flow
            )
            return EVMAddress(bytes: addressBytes)
        }

        /// Calls a function with the given data.
        /// The execution is limited by the given amount of gas
        access(all)
        fun call(
            to: EVMAddress,
            data: [UInt8],
            gasLimit: UInt64,
            value: Balance
        ): [UInt8] {
             return InternalEVM.call(
                 from: self.addressBytes,
                 to: to.bytes,
                 data: data,
                 gasLimit: gasLimit,
                 value: value.flow
            )
        }

        /// Bridges the given NFT to the EVM environment
        access(all)
        fun depositNFT(nft: @{NonFungibleToken.NFT}, to: EVM.EVMAddress, fee: @FlowToken.Vault) {
            EVM.borrowBridgeAccessor().depositNFT(nft: <-nft, to: to, fee: <-fee)
        }

        /// Bridges the given NFT to the EVM environment
        access(all)
        fun withdrawNFT(type: Type, id: UInt256, fee: @FlowToken.Vault): @{NonFungibleToken.NFT} {
            return <- EVM.borrowBridgeAccessor().withdrawNFT(caller: &self, type: type, id: id, fee: <-fee)
        }
    }

    /// Creates a new bridged account
    access(all)
    fun createBridgedAccount(): @BridgedAccount {
        return <-create BridgedAccount(
            addressBytes: InternalEVM.createBridgedAccount()
        )
    }

    /// Runs an a RLP-encoded EVM transaction, deducts the gas fees,
    /// and deposits the gas fees into the provided coinbase address.
    ///
    /// Returns true if the transaction was successful,
    /// and returns false otherwise
    access(all)
    fun run(tx: [UInt8], coinbase: EVMAddress) {
        InternalEVM.run(tx: tx, coinbase: coinbase.bytes)
    }

    access(all)
    fun encodeABI(_ values: [AnyStruct]): [UInt8] {
        return InternalEVM.encodeABI(values)
    }

    access(all)
    fun decodeABI(types: [Type], data: [UInt8]): [AnyStruct] {
        return InternalEVM.decodeABI(types: types, data: data)
    }

    /// Returns a reference to the BridgeAccessor designated for internal bridge requests
    ///
    access(self)
    fun borrowBridgeAccessor(): auth(Bridge) &{BridgeAccessor} {
        return self.account.storage.borrow<auth(Bridge) &{BridgeAccessor}>(from: /storage/evmBridgeRouter)
            ?? panic("Could not borrow reference to the EVM bridge")
    }

    /// Interface for a resource which acts as an entrypoint to the VM bridge
    access(all) resource interface BridgeAccessor {
        access(Bridge)
        fun depositNFT(nft: @{NonFungibleToken.NFT}, to: EVM.EVMAddress, fee: @{FungibleToken.Vault})
        access(Bridge)
        fun withdrawNFT(caller: &BridgedAccount, type: Type, id: UInt256, fee: @{FungibleToken.Vault}): @{NonFungibleToken.NFT}
    }
}