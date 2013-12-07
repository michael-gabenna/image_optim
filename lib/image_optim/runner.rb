# encoding: UTF-8

require 'image_optim'
require 'image_optim/hash_helpers'
require 'image_optim/true_false_nil'
require 'progress'
require 'optparse'
require 'find'
require 'yaml'

class ImageOptim
  class Runner
    module Space
      SIZE_SYMBOLS = %w[B K M G T P E Z Y].freeze
      PRECISION = 1
      LENGTH = 4 + PRECISION + 1
      COEF = 1 / Math.log(10)

      EMPTY_SPACE = ' ' * LENGTH
      NOT_COUNTED_SPACE = '!' * LENGTH

      class << self
        attr_writer :base10
        def denominator
          @denominator ||= @base10 ? 1000.0 : 1024.0
        end

        def space(size, options = {})
          case size
          when false
            NOT_COUNTED_SPACE.bold.red
          when 0, nil
            EMPTY_SPACE
          else
            number, degree = size, 0
            while number.abs >= 1000 && degree < SIZE_SYMBOLS.length - 1
              number /= denominator
              degree += 1
            end

            "#{degree == 0 ? number.to_s : "%.#{PRECISION}f" % number}#{SIZE_SYMBOLS[degree]}".rjust(LENGTH)
          end
        end
      end
    end

    class << self

      def run!(args)
        args = args.dup

        options = parse_options!(args)

        if options[:verbose]
          puts YAML.dump('Options' => HashHelpers.deep_stringify_keys(options)).sub(/\A---\n/, '')
        end

        recursive = options.delete(:recursive)

        image_optim = begin
          ImageOptim.new(options)
        rescue ImageOptim::ConfigurationError => e
          abort e.to_s
        end

        if args.empty?
          abort 'no paths to optimize'
        end

        files = get_optimisable_files(args, image_optim, recursive)

        files = files.with_progress('optimizing')
        results = image_optim.optimize_images(files) do |src, dst|
          if dst
            src_size, dst_size = src.size, dst.size
            percent = size_percent(src_size, dst_size)
            dst.replace(src)
            ["#{percent}  #{src}", src_size, dst_size]
          else
            ["------ #{Space::EMPTY_SPACE}  #{src}", src.size, src.size]
          end
        end
        lines, src_sizes, dst_sizes = results.transpose
        if lines
          $stdout.puts lines, "Total: #{size_percent(src_sizes.inject(:+), dst_sizes.inject(:+))}\n"
        end
      end

    private

      def size_percent(src_size, dst_size)
        '%5.2f%% %s' % [100 - 100.0 * dst_size / src_size, Space.space(src_size - dst_size)]
      end

      def get_optimisable_files(args, image_optim, recursive)
        files = []
        args.each do |arg|
          if File.file?(arg)
            if image_optim.optimizable?(arg)
              files << arg
            else
              warn "#{arg} is not an image or there is no optimizer for it"
            end
          else
            if recursive
              Find.find(arg) do |path|
                files << path if File.file?(path) && image_optim.optimizable?(path)
              end
            else
              warn "#{arg} is not a file"
            end
          end
        end
        files
      end

      def parse_options!(args)
        options = {}

        parser = option_parser(options)
        begin
          parser.parse!(args)
        rescue OptionParser::ParseError => e
          abort "#{e.to_s}\n\n#{parser.help}"
        end

        options
      end

      def option_parser(options)
        OptionParser.new do |op|
          op.accept(ImageOptim::TrueFalseNil, OptionParser.top.atype[TrueClass][0].merge('nil' => nil)){ |arg, val| val }

          op.banner = <<-TEXT.gsub(/^\s*\|/, '')
            |#{op.program_name} v#{ImageOptim.version}
            |
            |Usege:
            |  #{op.program_name} [options] image_path …
            |
          TEXT

          op.on('-r', '-R', '--recursive', 'Recurively scan directories for images') do |recursive|
            options[:recursive] = recursive
          end

          op.separator nil

          op.on('--[no-]threads N', Integer, 'Number of threads or disable (defaults to number of processors)') do |threads|
            options[:threads] = threads
          end

          op.on('--[no-]nice N', Integer, 'Nice level (defaults to 10)') do |nice|
            options[:nice] = nice
          end

          op.separator nil
          op.separator '  Disabling workers:'

          ImageOptim::Worker.klasses.each do |klass|
            bin = klass.bin_sym
            op.on("--no-#{bin}", "disable #{bin} worker") do |enable|
              options[bin] = enable
            end
          end

          op.separator nil
          op.separator '  Worker options:'

          ImageOptim::Worker.klasses.each_with_index do |klass, i|
            op.separator nil unless i.zero?

            bin = klass.bin_sym
            klass.option_definitions.each do |option_definition|
              name = option_definition.name.to_s.gsub('_', '-')
              default = option_definition.default
              type = option_definition.type

              type, marking = case
              when [TrueClass, FalseClass, ImageOptim::TrueFalseNil].include?(type)
                [type, 'B']
              when Integer >= type
                [Integer, 'N']
              when Array >= type
                [Array, 'a,b,c']
              else
                raise "Unknown type #{type}"
              end

              description = "#{option_definition.description.gsub(' - ', ' - ')} (defaults to #{default})"
              description = description.scan(/(.*?.{1,60})(?:\s|\z)/).flatten.join("\n  ").split("\n")

              op.on("--#{bin}-#{name} #{marking}", type, *description) do |value|
                options[bin] = {} unless options[bin].is_a?(Hash)
                options[bin][option_definition.name.to_sym] = value
              end
            end
          end

          op.separator nil
          op.separator '  Common options:'

          op.on('-v', '--verbose', 'Verbose output') do |verbose|
            options[:verbose] = verbose
          end

          op.on_tail('-h', '--help', 'Show full help') do
            puts op.help
            exit
          end

          op.on_tail('--version', 'Show version') do
            puts ImageOptim.version
            exit
          end
        end
      end

    end

  end
end
