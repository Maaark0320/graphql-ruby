# frozen_string_literal: true
module GraphQL
  module StaticValidation
    module VariablesAreInputTypes
      def on_variable_definition(node, parent)
        type_name = get_type_name(node.type)
        type = context.warden.get_type(type_name)

        if type.nil?
          add_error("#{type_name} isn't a defined input type (on $#{node.name})", node)
        elsif !type.kind.input?
          add_error("#{type.name} isn't a valid input type (on $#{node.name})", node)
        end

        super
      end

      private

      def get_type_name(ast_type)
        if ast_type.respond_to?(:of_type)
          get_type_name(ast_type.of_type)
        else
          ast_type.name
        end
      end
    end
  end
end