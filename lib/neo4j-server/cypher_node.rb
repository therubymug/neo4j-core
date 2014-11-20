module Neo4j::Server
  class CypherNode < Neo4j::Node
    include Neo4j::Server::Resource
    include Neo4j::Core::CypherTranslator
    include Neo4j::Core::ActiveEntity

    def initialize(session, value)
      @session = session

      @id = if value.is_a?(Hash)
        hash = value['data']
        @props = Hash[hash.map{ |k, v| [k.to_sym, v] }]
        @labels = value['metadata']['labels'].map(&:to_sym) if value['metadata']
        value['id'] # value['self'].match(/\d+$/)[0].to_i
      else
        value
      end
    end

    def neo_id
      @id
    end

    def inspect
      "CypherNode #{neo_id} (#{object_id})"
    end

    # TODO, needed by neo4j-cypher
    def _java_node
      self
    end

    # (see Neo4j::Node#create_rel)
    def create_rel(type, other_node, props = nil)
      q = "MATCH (a), (b) WHERE ID(a) = #{neo_id} AND ID(b) = #{other_node.neo_id} CREATE (a)-[r:`#{type}` #{cypher_prop_list(props)}]->(b) RETURN ID(r)"
      id = @session._query_or_fail(q, true)
      data_hash = { 'type' => type, 'data' => props, 'start' => self.neo_id.to_s, 'end' => other_node.neo_id.to_s, 'id' => id }
      CypherRelationship.new(@session, data_hash)
    end

    # (see Neo4j::Node#props)
    def props
      if @props
        @props
      else
        hash = @session._query_entity_data("#{match_start} RETURN n")
        @props = Hash[hash['data'].map{ |k, v| [k.to_sym, v] }]
      end
    end

    def refresh
      @props = nil
    end

    # (see Neo4j::Node#remove_property)
    def remove_property(key)
      refresh
      @session._query_or_fail("#{match_start} REMOVE n.`#{key}`")
    end

    # (see Neo4j::Node#set_property)
    def set_property(key,value)
      refresh
      @session._query_or_fail("#{match_start} SET n.`#{key}` = { value }", false, value: value)
      value
    end

    # (see Neo4j::Node#props=)
    def props=(properties)
      refresh
      @session._query_or_fail("#{match_start} SET n = { props }", false, {props: properties})
      properties
    end

    def remove_properties(properties)
      refresh
      q = "#{match_start} REMOVE " + properties.map do |k|
        "n.`#{k}`"
      end.join(', ')
      @session._query_or_fail(q)
    end

    # (see Neo4j::Node#update_props)
    def update_props(properties)
      refresh
      return if properties.empty?

      removed_keys = properties.keys.select{|k| properties[k].nil?}
      remove_properties(removed_keys) unless removed_keys.empty?
      properties_to_set = properties.keys - removed_keys
      return if properties_to_set.empty?
      q = "#{match_start} SET " + properties_to_set.map do |k|
        "n.`#{k}`= #{escape_value(properties[k])}"
      end.join(',')
      @session._query_or_fail(q)
      properties
    end

    # (see Neo4j::Node#get_property)
    def get_property(key)
      if @props
        @props[key.to_sym]
      else
        @session._query_or_fail("#{match_start} RETURN n.`#{key}`", true)
      end
    end

    # (see Neo4j::Node#labels)
    def labels
      @labels ||= @session._query_or_fail("#{match_start} RETURN labels(n) as labels", true)

      @labels.map(&:to_sym)
    end

    def _cypher_label_list(labels)
      ':' + labels.map{|label| "`#{label}`"}.join(':')
    end

    def add_label(*labels)
      @session._query_or_fail("#{match_start} SET n #{_cypher_label_list(labels)}")
    end

    def remove_label(*labels)
      @session._query_or_fail("#{match_start} REMOVE n #{_cypher_label_list(labels)}")
    end

    def set_label(*label_names)
      label_as_symbols = label_names.map(&:to_sym)
      to_keep = labels & label_as_symbols
      to_remove = labels - to_keep
      to_set = label_as_symbols - to_keep

      # no change ?
      return if to_set.empty? && to_remove.empty?

      q = "#{match_start}"
      q += " SET n #{_cypher_label_list(to_set)}" unless to_set.empty?
      q += " REMOVE n #{_cypher_label_list(to_remove)}" unless to_remove.empty?

      @session._query_or_fail(q)
    end

    # (see Neo4j::Node#del)
    def del
      @session._query_or_fail("#{match_start} MATCH n-[r]-() DELETE r")
      @session._query_or_fail("#{match_start} DELETE n")
    end
    alias_method :delete, :del
    alias_method :destroy, :del


    # (see Neo4j::Node#exist?)
    def exist?
      response = @session._query("#{match_start} RETURN ID(n)")
      response.data.empty? ? false : true
    end


    # (see Neo4j::Node#node)
    def node(match={})
      result = match(CypherNode, "p as result LIMIT 2", match)
      raise "Expected to only find one relationship from node #{neo_id} matching #{match.inspect} but found #{result.count}" if result.count > 1
      result.first
    end

    # (see Neo4j::Node#rel)
    def rel(match={})
      result = match(CypherRelationship, "r as result LIMIT 2", match)
      raise "Expected to only find one relationship from node #{neo_id} matching #{match.inspect} but found #{result.count}" if result.count > 1
      result.first
    end

    # (see Neo4j::Node#rel?)
    def rel?(match={})
      result = match(CypherRelationship, "r as result", match)
      !!result.first
    end

    # (see Neo4j::Node#nodes)
    def nodes(match={})
      match(CypherNode, "p as result", match)
    end


    # (see Neo4j::Node#rels)
    def rels(match = {dir: :both})
      match(CypherRelationship, "r as result", match)
    end

    # @private
    def match(clazz, returns, match={})
      to_dir = {outgoing: ->(rel) {"-#{rel}->"},
                incoming: ->(rel) {"<-#{rel}-"},
                both:     ->(rel) {"-#{rel}-"} }

      cypher_rel = match[:type] ? "[r:`#{match[:type]}`]" : '[r]'
      between_id = match[:between] ? "MATCH (p) WHERE ID(p) = #{match[:between].neo_id}" : ""
      dir_func = to_dir[match[:dir] || :both]
      cypher = "#{match_start} #{between_id} MATCH (n)#{dir_func.call(cypher_rel)}(p) RETURN #{returns}"
      r = @session._query(cypher)
      r.raise_error if r.error?
      _map_result(r)
    end

    def _map_result(r)
      r.to_node_enumeration.map { |rel| rel.result }
    end

    private

    def match_start(identifier = 'n')
      "MATCH (#{identifier}) WHERE ID(#{identifier}) = #{neo_id}"
    end
  end
end
