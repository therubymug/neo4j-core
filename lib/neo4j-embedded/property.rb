
# TODO code duplication with the Neo4j::PropertyContainer,
# This module should extend that module by adding transaction around methods
module Neo4j::Embedded::Property
  extend Neo4j::Core::TxMethods

  def valid_property?(value)
    Neo4j::Node::VALID_PROPERTY_VALUE_CLASSES.include?(value.class)
  end

  def []=(key,value)
    unless valid_property?(value) # TODO DRY
      raise Neo4j::InvalidPropertyException.new("Not valid Neo4j Property value #{value.class}, valid: #{Neo4j::Node::VALID_PROPERTY_VALUE_CLASSES.to_a.join(', ')}")
    end

    if value.nil?
      remove_property(key)
    else
      set_property(key.to_s, value)
    end
  end
  tx_methods :[]=

  def [](key)
    return nil unless has_property?(key.to_s)
    get_property(key.to_s)
  end
  tx_methods :[]

  def props
    property_keys.inject({}) do |ret, key|
      ret[key.to_sym] = get_property(key)
      ret
    end
  end
  tx_methods :props

  def neo_id
    get_id
  end
end