module MotherBrain
  module Chef
    # Handles loading configuration values from a Chef config file
    class Config < Hash
      DEFAULT_PATHS = %w[
        ./.chef/knife.rb
        ~/.chef/knife.rb
        /etc/chef/solo.rb
        /etc/chef/client.rb
      ]

      # @param [String] path
      def initialize(path = nil)
        @path = path
      end

      # Parse the file for the path and store symbolicated keys for knife
      # configuration options.
      #
      # @return [Knife] self
      def parse
        parse_file
        self
      end

      private

        def parse_file
          lines.each { |line| parse_line line }
        end

        def parse_line(line)
          eval line, binding
        rescue
        end

        def method_missing(key, value = nil)
          store key.to_sym, value
        end

        def lines
          file_contents.lines.to_a
        end

        def file_contents
          File.read(file_path)
        rescue
          String.new
        end

        def file_path
          File.expand_path(path)
        end

        def path
          @path ||= DEFAULT_PATHS.find { |path|
            File.exist?(File.expand_path(path))
          }
        end

        # Because it's common to set the local variable current_dir in a knife.rb
        # and then interpolate that into strings, set it here because that's hard
        # to parse.
        def current_dir
          File.dirname(file_path)
        end
    end
  end
end
