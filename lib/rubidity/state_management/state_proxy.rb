class StateProxy
  include ContractErrors
  
  attr_reader :state_variables, :unused_variables
  
  def initialize(definitions)
    @state_variables = {}.with_indifferent_access
    @unused_variables = {}.with_indifferent_access
    @dirty_stack = []
    
    definitions.each do |name, definition|
      @state_variables[name] = StateVariable.create(
        name,
        definition[:type],
        definition[:args],
        on_change: method(:mark_dirty)
      )
    end
  end
  
  def detecting_changes(revert_on_change:)
    @dirty_stack.push(false)
    
    yield
    
    if @dirty_stack.last && revert_on_change
      raise InvalidStateVariableChange.new
    end
  ensure
    @dirty_stack.pop
  end
  
  def mark_dirty
    return if @dirty_stack.empty?
    
    @dirty_stack[-1] = true
  end
  
  def method_missing(name, *args)
    is_setter = name[-1] == '='
    var_name = is_setter ? name[0...-1].to_s : name.to_s
    
    var = state_variables[var_name]
    
    return super if var.nil?

    if is_setter
      var.typed_variable = args.first
    else
      var.typed_variable
    end
  end
  
  def serialize(dup: true)
    val = state_variables.each.with_object({}) do |(key, value), h|
      h[key] = value.serialize
    end.reverse_merge(unused_variables)
    
    dup ? val.deep_dup : val
  end
  
  def deserialize(state_data)
    state_data.each do |var_name, value|
      if var = state_variables[var_name]
        var.deserialize(value)
      else
        unused_variables[var_name] = value
      end
    end
  end
  alias_method :load, :deserialize
end
