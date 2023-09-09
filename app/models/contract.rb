class Contract < ApplicationRecord
  self.inheritance_column = :_type_disabled
  
  include ContractErrors
    
  belongs_to :ethscription, primary_key: 'ethscription_id', foreign_key: 'ethscription_id',
    class_name: "Ethscription", touch: true
  has_many :call_receipts, primary_key: 'address', foreign_key: 'contract_address', class_name: "ContractCallReceipt"
  has_many :states, primary_key: 'address', foreign_key: 'contract_address', class_name: "ContractState"
  
  attr_accessor :current_transaction
  attr_reader :implementation
  
  delegate :msg, to: :implementation
  
  def self.create_from_user!(deployer:, creation_ethscription_id:, type:)
    unless valid_contract_types.include?(type)
      raise TransactionError.new("Invalid contract type: #{type}")
    end
    
    implementation_class = "Contracts::#{type}".constantize
    
    if implementation_class.is_abstract_contract
      raise TransactionError.new("Cannot deploy abstract contract: #{type}")
    end
    
    address = User.calculate_contract_address(
      deployer: deployer,
      current_tx_ethscription_id: creation_ethscription_id
    )
    
    Contract.create!(
      ethscription_id: creation_ethscription_id,
      address: address,
      type: type,
    )
  end
  
  def implementation
    @implementation ||= implementation_class.new(self)
  end
  
  def implementation_class
    "Contracts::#{type}".constantize
  end
  
  def current_state
    states.newest_first.first || ContractState.new
  end
  
  def execute_function(function_name, user_args, persist_state:)
    begin
      with_state_management(persist_state: persist_state) do
        implementation.send(function_name, *user_args[:args], **user_args[:kwargs])
      end
    rescue ContractError => e
      e.contract = self
      raise e
    end
  end
  
  def with_state_management(persist_state:)
    implementation.state_proxy.load(current_state.state.deep_dup)
    initial_state = implementation.state_proxy.serialize
    
    yield.tap do
      final_state = implementation.state_proxy.serialize
      
      if (final_state != initial_state) && persist_state
        states.create!(
          ethscription_id: current_transaction.ethscription.ethscription_id,
          state: final_state
        )
      end
    end
  end
  
  def self.all_abis(deployable_only: false)
    contract_classes = valid_contract_types

    contract_classes.each_with_object({}) do |name, hash|
      contract_class = "Contracts::#{name}".constantize

      next if deployable_only && contract_class.is_abstract_contract

      hash[contract_class.name] = contract_class.public_abi
    end.transform_keys(&:demodulize)
  end
  
  def as_json(options = {})
    super(
      options.merge(
        only: [
          :address,
          :ethscription_id,
        ]
      )
    ).tap do |json|
      json['abi'] = implementation.public_abi.map do |name, func|
        [name, func.as_json.except('implementation')]
      end.to_h
      
      json['current_state'] = current_state.state
      json['current_state']['contract_type'] = type.demodulize
      
      klass = implementation.class
      tree = [klass, klass.linearized_parents].flatten
      
      json['source_code'] = tree.map do |k|
        {
          language: 'ruby',
          code: source_code(k)
        }
      end
    end
  end
  
  def self.valid_contract_types
    Contracts.constants.map do |c|
      Contracts.const_get(c).to_s.demodulize
    end
  end
  
  def static_call(name, args = {})
    ContractTransaction.make_static_call(
      contract: address, 
      function_name: name, 
      function_args: args
    )
  end

  def source_file(type)
    ActiveSupport::Dependencies.autoload_paths.each do |base_folder|
      relative_path = "#{type.to_s.underscore}.rb"
      absolute_path = File.join(base_folder, relative_path)

      return absolute_path if File.file?(absolute_path)
    end
    nil
  end

  def source_code(type)
    File.read(source_file(type)) if source_file(type)
  end
end
