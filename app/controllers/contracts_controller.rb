class ContractsController < ApplicationController
  def index
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 50).to_i
    per_page = 50 if per_page > 50
    
    scope = Contract.
      order(created_at: :desc).
      where.not(current_init_code_hash: nil).
      includes(:transaction_receipt)
    
    if params[:base_type]
      scope = scope.where(
        current_type: Contract.types_that_implement(params[:base_type]).map(&:name)
      )
    end
    
    if params[:init_code_hash]
      scope = scope.where(current_init_code_hash: params[:init_code_hash])
    end
    
    cache_key = ["contracts_index", scope, page, per_page]
  
    result = Rails.cache.fetch(cache_key) do
      contracts = scope.page(page).per(per_page).to_a
      numbers_to_strings(contracts)
    end
  
    render json: {
      result: result,
      count: scope.count
    }
  end

  def supported_contract_artifacts
    render json: {
      result: SystemConfigVersion.current_supported_contract_artifacts
    }
  end
  
  def all_abis
    render json: {
      result: Contract.all_abis
    }
  end

  def deployable_contracts
    render json: {
      result: Contract.all_abis(deployable_only: true)
    }
  end

  def show
    expires_in(6, "s-maxage": 12.seconds, public: true)
    
    contract = Contract.find_by_address(params[:id])

    if contract.blank?
      render json: { error: "Contract not found" }, status: 404
      return
    end

    render json: {
      result: numbers_to_strings(contract.as_json(include_current_state: true))
    }
  end

  def static_call
    expires_in(6, "s-maxage": 12.seconds, public: true)
    
    args = JSON.parse(params.fetch(:args) { '{}' })
    env = JSON.parse(params.fetch(:env) { '{}' })

    begin
      result = ContractTransaction.make_static_call(
        contract: params[:address], 
        function_name: params[:function], 
        function_args: args,
        msgSender: env['msgSender']
      )
    rescue Contract::StaticCallError => e
      render json: {
        error: e.message
      }
      return
    end

    render json: {
      result: numbers_to_strings(result)
    }
  end
  
  def storage_get
    address = params[:address]&.downcase
    first_key = params[:first_key]
    raw_args = params[:args].presence || "[]"
    
    parsed_args = begin
      JSON.parse(raw_args)
    rescue JSON::ParserError
      raw_args
    end
  
    args = if parsed_args.is_a?(Hash)
      parsed_args.values
    else
      Array.wrap(parsed_args)
    end
    
    args = [first_key] + args
    
    args.map! do |param|
      param =~ /\A0x([a-f0-9]{2})+\z/i ? param.downcase : param
    end
  
    updated_at = Contract.where(address: address).pick(:updated_at)
    
    if updated_at.blank?
      render json: { error: "Contract not found" }, status: :not_found
      return
    end
    
    args_hash = Digest::SHA1.hexdigest(args.to_json)
    
    cache_key = [
      "contracts_storage_get",
      address,
      updated_at,
      args_hash
    ]
    
    set_cache_control_headers(etag: cache_key, max_age: 12.seconds) do
      result = Rails.cache.fetch(cache_key) do
        Contract.get_storage_value_by_path(address, args)
      end
      
      render json: { result: result }
    end
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.message.starts_with?("PG::InvalidTextRepresentation")
    
    render json: { error: "Invalid args: #{e.message}" }, status: :bad_request
  end

  def show_call_receipt
    receipt = TransactionReceipt.includes(:contract_transaction).find_by_transaction_hash(params[:transaction_hash])

    if receipt.blank?
      render json: {
        error: "Call receipt not found"
      }
    else
      render json: {
        result: numbers_to_strings(receipt)
      }
    end
  end

  def simulate_transaction
    expires_in(6, "s-maxage": 12.seconds, public: true)
    
    from = params[:from]
    
    tx_payload = if request.method == 'POST'
      JSON.parse(request.raw_post)
    else
      JSON.parse(params[:tx_payload])
    end
    
    begin
      receipt = ContractTransaction.simulate_transaction(
        from: from, tx_payload: tx_payload
      )
    rescue => e
      # Airbrake.notify(e)
      render json: { error: e.message }, status: 500
      return
    end
  
    render json: { result: numbers_to_strings(receipt) }
  end
  
  def pairs_for_router
    expires_in(6, "s-maxage": 12.seconds, public: true)
    
    user_address = params[:user_address]&.downcase
    router_address = params[:router]&.downcase
    
    cache_key = [
      "pairs_for_router",
      router_address,
      user_address,
      EthBlock.max_processed_block_number
    ]
    
    result = Rails.cache.fetch(cache_key) do
      router = Contract.find_by_address(router_address)
      weth_address = router.current_state['WETH']
      
      factory = Contract.find_by_address(router.current_state['factory'])
      
      pairs = Contract.where(address: factory.current_state['allPairs'])
      
      pairs = pairs.select do |pair|
        pair.current_state['token0'] == weth_address || pair.current_state['token1'] == weth_address
      end
      
      all_tokens = pairs.map do |pair|
        [pair.current_state['token0'], pair.current_state['token1']]
      end.flatten.uniq
      
      all_tokens = Contract.where(address: all_tokens).index_by(&:address)
      
      pairs.each_with_object({}) do |pair, result|
        token0_address = pair.current_state['token0']
        token1_address = pair.current_state['token1']
      
        token0 = all_tokens[token0_address]
        token1 = all_tokens[token1_address]
      
        pair_info = {
          token0: {
            address: token0_address,
            name: token0.current_state['name'],
            symbol: token0.current_state['symbol']
          },
          token1: {
            address: token1_address,
            name: token1.current_state['name'],
            symbol: token1.current_state['symbol']
          },
          lp_reserves: {
            token0: pair.current_state['reserve0'],
            token1: pair.current_state['reserve1']
          }
        }
        
        if pair.current_state['token0'] == weth_address
          weth_reserves = pair.current_state['reserve0'].to_i
        elsif pair.current_state['token1'] == weth_address
          weth_reserves = pair.current_state['reserve1'].to_i
        end
      
        pair_info[:tvl_in_weth] = weth_reserves * 2
        
        if user_address
          pair_info[:user_balances] = {
            lp: pair.current_state['balanceOf'][user_address].to_i,
            token0: token0.current_state['balanceOf'][user_address].to_i,
            token1: token1.current_state['balanceOf'][user_address].to_i
          }
      
          pair_info[:user_allowances] = {
            lp: pair.current_state.dig('allowance', user_address, router_address).to_i,
            token0: token0.current_state.dig('allowance', user_address, router_address).to_i,
            token1: token1.current_state.dig('allowance', user_address, router_address).to_i
          }
        end
      
        result[pair.address] = pair_info
      end
    end
    
    render json: numbers_to_strings(result)
  end
  
  def pairs_with_tokens
    router = params[:router]
    token_address = params[:token_address]
    user_address = params[:user_address]
  
    cache_key = [
      :pairs_with_tokens,
      EthBlock.max_processed_block_number,
      router,
      token_address,
      user_address
    ]
  
    pairs = Rails.cache.fetch(cache_key) do
      factory = make_static_call(
        contract: router,
        function_name: "factory"
      )
  
      pair_ary = make_static_call(
        contract: factory,
        function_name: "getAllPairs"
      )
  
      # Load pair_ary into memory
      contracts = Contract.where(address: pair_ary)
  
      # Fetch all token contracts in bulk
      token_addresses = contracts.map do |contract|
        [
          contract.fresh_implementation_with_current_state.token0,
          contract.fresh_implementation_with_current_state.token1
        ]
      end.flatten
      
      token_contracts = Contract.where(address: token_addresses.map(&:value)).index_by(&:address)
  
      result = contracts.each_with_object({}) do |contract, hash|
        ["token0", "token1"].each do |token_function|
          token_addr = contract.fresh_implementation_with_current_state.public_send(token_function)
          contract_implementation = token_contracts[token_addr.value].fresh_implementation_with_current_state
  
          token_info = {
            address: token_addr,
            name: contract_implementation.name,
            symbol: contract_implementation.symbol
          }
  
          if user_address.present?
            token_info[:userBalance] = contract_implementation.balanceOf(user_address)
            token_info[:allowance] = contract_implementation.allowance(user_address, router)
          end
  
          hash[contract.address] ||= {}
          hash[contract.address][token_function] = token_info
        end
      end
      
      numbers_to_strings(result)
    end
  
    render json: { result: pairs }
  rescue Contract::StaticCallError => e
    render json: {
      error: e.message
    }
  end
  
  def make_static_call(**kwargs)
    ContractTransaction.make_static_call(**kwargs)
  end
end
