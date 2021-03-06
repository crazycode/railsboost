require 'enumerator'
require 'sass/tree/node'
require 'sass/tree/value_node'
require 'sass/tree/rule_node'
require 'sass/tree/comment_node'
require 'sass/tree/attr_node'
require 'sass/tree/directive_node'
require 'sass/constant'
require 'sass/error'
require 'haml/shared'

module Sass
  # This is the class where all the parsing and processing of the Sass
  # template is done. It can be directly used by the user by creating a
  # new instance and calling <tt>render</tt> to render the template. For example:
  #
  #   template = File.load('stylesheets/sassy.sass')
  #   sass_engine = Sass::Engine.new(template)
  #   output = sass_engine.render
  #   puts output
  class Engine
    Line = Struct.new(:text, :tabs, :index, :children)

    # The character that begins a CSS attribute.
    ATTRIBUTE_CHAR  = ?:

    # The character that designates that
    # an attribute should be assigned to the result of constant arithmetic.
    SCRIPT_CHAR     = ?=

    # The character that designates the beginning of a comment,
    # either Sass or CSS.
    COMMENT_CHAR = ?/

    # The character that follows the general COMMENT_CHAR and designates a Sass comment,
    # which is not output as a CSS comment.
    SASS_COMMENT_CHAR = ?/

    # The character that follows the general COMMENT_CHAR and designates a CSS comment,
    # which is embedded in the CSS document.
    CSS_COMMENT_CHAR = ?*

    # The character used to denote a compiler directive.
    DIRECTIVE_CHAR = ?@

    # Designates a non-parsed rule.
    ESCAPE_CHAR    = ?\\

    # Designates block as mixin definition rather than CSS rules to output
    MIXIN_DEFINITION_CHAR = ?=

    # Includes named mixin declared using MIXIN_DEFINITION_CHAR
    MIXIN_INCLUDE_CHAR    = ?+

    # The regex that matches and extracts data from
    # attributes of the form <tt>:name attr</tt>.
    ATTRIBUTE = /^:([^\s=:]+)\s*(=?)(?:\s+|$)(.*)/

    # The regex that matches attributes of the form <tt>name: attr</tt>.
    ATTRIBUTE_ALTERNATE_MATCHER = /^[^\s:]+\s*[=:](\s|$)/

    # The regex that matches and extracts data from
    # attributes of the form <tt>name: attr</tt>.
    ATTRIBUTE_ALTERNATE = /^([^\s=:]+)(\s*=|:)(?:\s+|$)(.*)/

    # Creates a new instace of Sass::Engine that will compile the given
    # template string when <tt>render</tt> is called.
    # See README.rdoc for available options.
    #
    #--
    #
    # TODO: Add current options to REFRENCE. Remember :filename!
    #
    # When adding options, remember to add information about them
    # to README.rdoc!
    #++
    #
    def initialize(template, options={})
      @options = {
        :style => :nested,
        :load_paths => ['.']
      }.merge! options
      @template = template
      @constants = {"important" => "!important"}
      @mixins = {}
    end

    # Processes the template and returns the result as a string.
    def render
      begin
        render_to_tree.to_s
      rescue SyntaxError => err
        unless err.sass_filename
          err.add_backtrace_entry(@options[:filename])
        end
        raise err
      end
    end

    alias_method :to_css, :render

    protected

    def constants
      @constants
    end

    def mixins
      @mixins
    end

    def render_to_tree
      root = Tree::Node.new(@options)
      append_children(root, tree(tabulate(@template)).first, true)
      root
    end

    private

    def tabulate(string)
      tab_str = nil
      first = true
      string.gsub(/\r|\n|\r\n|\r\n/, "\n").scan(/^.*?$/).enum_with_index.map do |line, index|
        index += 1
        next if line.strip.empty? || line =~ /^\/\//

        line_tab_str = line[/^\s*/]
        unless line_tab_str.empty?
          tab_str ||= line_tab_str

          raise SyntaxError.new("Indenting at the beginning of the document is illegal.", index) if first
          if tab_str.include?(?\s) && tab_str.include?(?\t)
            raise SyntaxError.new("Indentation can't use both tabs and spaces.", index)
          end
        end
        first &&= !tab_str.nil?
        next Line.new(line.strip, 0, index, []) if tab_str.nil?

        line_tabs = line_tab_str.scan(tab_str).size
        raise SyntaxError.new(<<END.strip.gsub("\n", ' '), index) if tab_str * line_tabs != line_tab_str
Inconsistent indentation: #{Haml::Shared.human_indentation line_tab_str, true} used for indentation,
but the rest of the document was indented using #{Haml::Shared.human_indentation tab_str}.
END

        Line.new(line.strip, line_tabs, index, [])
      end.compact
    end

    def tree(arr, i = 0)
      base = arr[i].tabs
      nodes = []
      while (line = arr[i]) && line.tabs >= base
        if line.tabs > base
          if line.tabs > base + 1
            raise SyntaxError.new("The line was indented #{line.tabs - base} levels deeper than the previous line.", line.index)
          end

          nodes.last.children, i = tree(arr, i)
        else
          nodes << line
          i += 1
        end
      end
      return nodes, i
    end

    def build_tree(line)
      @line = line.index
      node = parse_line(line)

      # Node is a symbol if it's non-outputting, like a constant assignment
      unless node.is_a? Tree::Node
        unless line.children.empty?
          if node == :constant
            raise SyntaxError.new("Illegal nesting: Nothing may be nested beneath constants.", @line + 1)
          elsif node.is_a? Array
            # arrays can either be full of import statements
            # or attributes from mixin includes
            # in either case they shouldn't have children.
            # Need to peek into the array in order to give meaningful errors
            directive_type = (node.first.is_a?(Tree::DirectiveNode) ? "import" : "mixin")
            raise SyntaxError.new("Illegal nesting: Nothing may be nested beneath #{directive_type} directives.", @line + 1)
          end
        end
        return node
      end

      node.line = line.index
      node.filename = @options[:filename]

      unless node.is_a?(Tree::CommentNode)
        append_children(node, line.children, false)
      else
        node.children = line.children
      end
      return node
    end

    def append_children(parent, children, root)
      continued_rule = nil
      children.each do |line|
        child = build_tree(line)

        if child.is_a?(Tree::RuleNode) && child.continued?
          raise SyntaxError.new("Rules can't end in commas.", child.line) unless child.children.empty?
          if continued_rule
            continued_rule.add_rules child
          else
            continued_rule = child
          end
          next
        end

        if continued_rule
          raise SyntaxError.new("Rules can't end in commas.", continued_rule.line) unless child.is_a?(Tree::RuleNode)
          continued_rule.add_rules child
          continued_rule.children = child.children
          continued_rule, child = nil, continued_rule
        end

        validate_and_append_child(parent, child, line, root)
      end

      raise SyntaxError.new("Rules can't end in commas.", continued_rule.line) if continued_rule
    end

    def validate_and_append_child(parent, child, line, root)
      unless root
        case child
        when :constant
          raise SyntaxError.new("Constants may only be declared at the root of a document.", line.index)
        when :mixin
          raise SyntaxError.new("Mixins may only be defined at the root of a document.", line.index)
        when Tree::DirectiveNode
          raise SyntaxError.new("Import directives may only be used at the root of a document.", line.index)
        end
      end

      case child
      when Array
        child.each {|c| validate_and_append_child(parent, c, line, root)}
      when Tree::Node
        parent << child
      end
    end

    def parse_line(line)
      case line.text[0]
      when ATTRIBUTE_CHAR
        parse_attribute(line.text, ATTRIBUTE)
      when Constant::CONSTANT_CHAR
        parse_constant(line.text)
      when COMMENT_CHAR
        parse_comment(line.text)
      when DIRECTIVE_CHAR
        parse_directive(line.text)
      when ESCAPE_CHAR
        Tree::RuleNode.new(line.text[1..-1], @options)
      when MIXIN_DEFINITION_CHAR
        parse_mixin_definition(line)
      when MIXIN_INCLUDE_CHAR
        if line.text[1].nil? || line.text[1] == ?\s
          Tree::RuleNode.new(line.text, @options)
        else
          parse_mixin_include(line.text)
        end
      else
        if line.text =~ ATTRIBUTE_ALTERNATE_MATCHER
          parse_attribute(line.text, ATTRIBUTE_ALTERNATE)
        else
          Tree::RuleNode.new(line.text, @options)
        end
      end
    end

    def parse_attribute(line, attribute_regx)
      if @options[:attribute_syntax] == :normal &&
          attribute_regx == ATTRIBUTE_ALTERNATE
        raise SyntaxError.new("Illegal attribute syntax: can't use alternate syntax when :attribute_syntax => :normal is set.")
      elsif @options[:attribute_syntax] == :alternate &&
          attribute_regx == ATTRIBUTE
        raise SyntaxError.new("Illegal attribute syntax: can't use normal syntax when :attribute_syntax => :alternate is set.")
      end

      name, eq, value = line.scan(attribute_regx)[0]

      if name.nil? || value.nil?
        raise SyntaxError.new("Invalid attribute: \"#{line}\".", @line)
      end

      if eq.strip[0] == SCRIPT_CHAR
        value = Sass::Constant.parse(value, @constants, @line).to_s
      end

      Tree::AttrNode.new(name, value, @options)
    end

    def parse_constant(line)
      name, op, value = line.scan(Sass::Constant::MATCH)[0]
      unless name && value
        raise SyntaxError.new("Invalid constant: \"#{line}\".", @line)
      end

      constant = Sass::Constant.parse(value, @constants, @line)
      if op == '||='
        @constants[name] ||= constant
      else
        @constants[name] = constant
      end

      :constant
    end

    def parse_comment(line)
      if line[1] == SASS_COMMENT_CHAR
        :comment
      elsif line[1] == CSS_COMMENT_CHAR
        Tree::CommentNode.new(line, @options)
      else
        Tree::RuleNode.new(line, @options)
      end
    end

    def parse_directive(line)
      directive, value = line[1..-1].split(/\s+/, 2)

      # If value begins with url( or ",
      # it's a CSS @import rule and we don't want to touch it.
      if directive == "import" && value !~ /^(url\(|")/
        import(value)
      else
        Tree::DirectiveNode.new(line, @options)
      end
    end

    def parse_mixin_definition(line)
      append_children(@mixins[line.text[1..-1]] = [], line.children, false)
      :mixin
    end

    def parse_mixin_include(line)
      mixin_name = line[1..-1]
      unless @mixins.has_key?(mixin_name)
        raise SyntaxError.new("Undefined mixin '#{mixin_name}'.", @line)
      end
      @mixins[mixin_name]
    end

    def import(files)
      nodes = []

      files.split(/,\s*/).each do |filename|
        engine = nil

        begin
          filename = self.class.find_file_to_import(filename, @options[:load_paths])
        rescue Exception => e
          raise SyntaxError.new(e.message, @line)
        end

        if filename =~ /\.css$/
          nodes << Tree::DirectiveNode.new("@import url(#{filename})", @options)
        else
          File.open(filename) do |file|
            new_options = @options.dup
            new_options[:filename] = filename
            engine = Sass::Engine.new(file.read, new_options)
          end

          engine.constants.merge! @constants
          engine.mixins.merge! @mixins

          begin
            root = engine.render_to_tree
          rescue Sass::SyntaxError => err
            err.add_backtrace_entry(filename)
            raise err
          end
          nodes += root.children
          @constants = engine.constants
          @mixins = engine.mixins
        end
      end

      nodes
    end

    def self.find_file_to_import(filename, load_paths)
      was_sass = false
      original_filename = filename

      if filename[-5..-1] == ".sass"
        filename = filename[0...-5]
        was_sass = true
      elsif filename[-4..-1] == ".css"
        return filename
      end

      new_filename = find_full_path("#{filename}.sass", load_paths)

      if new_filename.nil?
        if was_sass
          raise Exception.new("File to import not found or unreadable: #{original_filename}.")
        else
          return filename + '.css'
        end
      else
        new_filename
      end
    end

    def self.find_full_path(filename, load_paths)
      load_paths.each do |path|
        ["_#{filename}", filename].each do |name|
          full_path = File.join(path, name)
          if File.readable?(full_path)
            return full_path
          end
        end
      end
      nil
    end
  end
end
