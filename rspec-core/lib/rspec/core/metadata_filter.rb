module RSpec
  module Core
    # Contains metadata filtering logic. This has been extracted from
    # the metadata classes because it operates ON a metadata hash but
    # does not manage any of the state in the hash. We're moving towards
    # having metadata be a raw hash (not a custom subclass), so externalizing
    # this filtering logic helps us move in that direction.
    module MetadataFilter
      class << self
        # @private
        def apply?(predicate, filters, metadata)
          filters.__send__(predicate) { |k, v| filter_applies?(k, v, metadata) }
        end

        # @private
        def filter_applies?(key, value, metadata)
          silence_metadata_example_group_deprecations do
            return filter_applies_to_any_value?(key, value, metadata) if Array === metadata[key] && !(Proc === value)
            return location_filter_applies?(value, metadata)          if key == :locations
            return id_filter_applies?(value, metadata)                if key == :ids
            return filters_apply?(key, value, metadata)               if Hash === value

            return false unless metadata.key?(key)

            case value
            when Regexp
              metadata[key] =~ value
            when Proc
              case value.arity
              when 0 then value.call
              when 2 then value.call(metadata[key], metadata)
              else value.call(metadata[key])
              end
            else
              metadata[key].to_s == value.to_s
            end
          end
        end

      private

        def filter_applies_to_any_value?(key, value, metadata)
          metadata[key].any? { |v| filter_applies?(key, v,  key => value) }
        end

        def id_filter_applies?(rerun_paths_to_scoped_ids, metadata)
          scoped_ids = rerun_paths_to_scoped_ids.fetch(metadata[:rerun_file_path]) { return false }

          Metadata.ascend(metadata).any? do |meta|
            scoped_ids.include?(meta[:scoped_id])
          end
        end

        def location_filter_applies?(locations, metadata)
          line_numbers = example_group_declaration_lines(locations, metadata)
          line_numbers.empty? || line_number_filter_applies?(line_numbers, metadata)
        end

        def line_number_filter_applies?(line_numbers, metadata)
          preceding_declaration_lines = line_numbers.map { |n| RSpec.world.preceding_declaration_line(n) }
          !(relevant_line_numbers(metadata) & preceding_declaration_lines).empty?
        end

        def relevant_line_numbers(metadata)
          Metadata.ascend(metadata).map { |meta| meta[:line_number] }
        end

        def example_group_declaration_lines(locations, metadata)
          FlatMap.flat_map(Metadata.ascend(metadata)) do |meta|
            locations[meta[:absolute_file_path]]
          end.uniq
        end

        def filters_apply?(key, value, metadata)
          subhash = metadata[key]
          return false unless Hash === subhash || HashImitatable === subhash
          value.all? { |k, v| filter_applies?(k, v, subhash) }
        end

        def silence_metadata_example_group_deprecations
          RSpec.thread_local_metadata[:silence_metadata_example_group_deprecations] = true
          yield
        ensure
          RSpec.thread_local_metadata.delete(:silence_metadata_example_group_deprecations)
        end
      end
    end

    # Tracks a collection of filterable items (e.g. modules, hooks, etc)
    # and provides an optimized API to get the applicable items for the
    # metadata of an example or example group.
    #
    # There are two implementations, optimized for different uses.
    # @private
    module FilterableItemRepository
      # This implementation is simple, and is optimized for frequent
      # updates but rare queries. `append` and `prepend` do no extra
      # processing, and no internal memoization is done, since this
      # is not optimized for queries.
      #
      # This is ideal for use by a example or example group, which may
      # be updated multiple times with globally configured hooks, etc,
      # but will not be queried frequently by other examples or examle
      # groups.
      # @private
      class UpdateOptimized
        attr_reader :items_and_filters

        def initialize(applies_predicate)
          @applies_predicate = applies_predicate
          @items_and_filters = []
        end

        def append(item, metadata)
          @items_and_filters << [item, metadata]
        end

        def prepend(item, metadata)
          @items_and_filters.unshift [item, metadata]
        end

        def items_for(request_meta)
          @items_and_filters.each_with_object([]) do |(item, item_meta), to_return|
            to_return << item if item_meta.empty? ||
                                 MetadataFilter.apply?(@applies_predicate, item_meta, request_meta)
          end
        end

        unless [].respond_to?(:each_with_object) # For 1.8.7
          undef items_for
          def items_for(request_meta)
            @items_and_filters.inject([]) do |to_return, (item, item_meta)|
              to_return << item if item_meta.empty? ||
                                   MetadataFilter.apply?(@applies_predicate, item_meta, request_meta)
              to_return
            end
          end
        end
      end

      # This implementation is much more complex, and is optimized for
      # rare (or hopefully no) updates once the queries start. Updates
      # incur a cost as it has to clear the memoization and keep track
      # of applicable keys. Queries will be O(N) the first time an item
      # is provided with a given set of applicable metadata; subsequent
      # queries with items with the same set of applicable metadata will
      # be O(1) due to internal memoization.
      #
      # This is ideal for use by config, where filterable items (e.g. hooks)
      # are typically added at the start of the process (e.g. in `spec_helper`)
      # and then repeatedly queried as example groups and examples are defined.
      # @private
      class QueryOptimized < UpdateOptimized
        alias find_items_for items_for
        private :find_items_for

        def initialize(applies_predicate)
          super
          @applicable_keys   = Set.new
          @proc_keys         = Set.new
          @memoized_lookups  = Hash.new do |hash, applicable_metadata|
            hash[applicable_metadata] = find_items_for(applicable_metadata)
          end
        end

        def append(item, metadata)
          super
          handle_mutation(metadata)
        end

        def prepend(item, metadata)
          super
          handle_mutation(metadata)
        end

        def items_for(metadata)
          # The filtering of `metadata` to `applicable_metadata` is the key thing
          # that makes the memoization actually useful in practice, since each
          # example and example group have different metadata (e.g. location and
          # description). By filtering to the metadata keys our items care about,
          # we can ignore extra metadata keys that differ for each example/group.
          # For example, given `config.include DBHelpers, :db`, example groups
          # can be split into these two sets: those that are tagged with `:db` and those
          # that are not. For each set, this method for the first group in the set is
          # still an `O(N)` calculation, but all subsequent groups in the set will be
          # constant time lookups when they call this method.
          applicable_metadata = applicable_metadata_from(metadata)

          if applicable_metadata.any? { |k, _| @proc_keys.include?(k) }
            # It's unsafe to memoize lookups involving procs (since they can
            # be non-deterministic), so we skip the memoization in this case.
            find_items_for(applicable_metadata)
          else
            @memoized_lookups[applicable_metadata]
          end
        end

      private

        def handle_mutation(metadata)
          @applicable_keys.merge(metadata.keys)
          @proc_keys.merge(proc_keys_from metadata)
          @memoized_lookups.clear
        end

        def applicable_metadata_from(metadata)
          @applicable_keys.inject({}) do |hash, key|
            hash[key] = metadata[key] if metadata.key?(key)
            hash
          end
        end

        def proc_keys_from(metadata)
          metadata.each_with_object([]) do |(key, value), to_return|
            to_return << key if Proc === value
          end
        end

        unless [].respond_to?(:each_with_object) # For 1.8.7
          undef proc_keys_from
          def proc_keys_from(metadata)
            metadata.inject([]) do |to_return, (key, value)|
              to_return << key if Proc === value
              to_return
            end
          end
        end
      end
    end
  end
end
