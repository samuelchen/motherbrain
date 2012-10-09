module MotherBrain
  module PluginDSL
    # @author Jamie Winsor <jamie@vialstudios.com>
    module Groups
      include PluginDSL::Base
      
      def group(&block)
        unless block_given?
          raise PluginSyntaxError, "Group definition missing a required block"
        end

        context.parent = self.real
        add_group Group.new(context, &block)
      end

      protected

        # @return [HashWithIndifferentAccess]
        def groups
          @groups ||= HashWithIndifferentAccess.new
        end

      private

        # @param [MB::Group] group
        def add_group(group)
          unless self.groups[group.id].nil?
            raise DuplicateGroup, "Group '#{group.name}' already defined"
          end

          self.groups[group.id] = group
        end

        # @param [#to_sym] name
        #
        # @return [MB::Group]
        def get_group(name)
          self.groups.fetch(name.to_sym, nil)
        end
    end
  end
end