require 'hocon/impl'
require 'hocon/impl/config_impl_util'
require 'hocon/impl/tokens'
require 'hocon/config_error'
require 'stringio'
require 'forwardable'

class Hocon::Impl::Tokenizer
  Tokens = Hocon::Impl::Tokens

  class TokenizerProblemError < StandardError
    def initialize(problem)
      @problem = problem
    end

    def problem
      @problem
    end
  end

  class TokenIterator
    extend Forwardable
    class WhitespaceSaver
      def initialize
        @whitespace = StringIO.new
        @last_token_was_simple_value = false
      end

      def add(c)
        if @last_token_was_simple_value
          @whitespace << c
        end
      end

      def check(t, base_origin, line_number)
        if TokenIterator.simple_value?(t)
          next_is_a_simple_value(base_origin, line_number)
        else
          next_is_not_a_simple_value
          nil
        end
      end

      def line_origin(base_origin, line_number)
        base_origin.set_line_number(line_number)
      end

      private
      # called if the next token is not a simple value;
      # discards any whitespace we were saving between
      # simple values.
      def next_is_not_a_simple_value
        @last_token_was_simple_value = false
        @whitespace.reopen("")
      end

      # called if the next token IS a simple value,
      # so creates a whitespace token if the previous
      # token also was.
      def next_is_a_simple_value(base_origin, line_number)
        if @last_token_was_simple_value
          # need to save whitespace between the two so
          # the parser has the option to concatenate it.
          if @whitespace.length > 0
            token = Tokens.new_unquoted_text(
                line_origin(base_origin, line_number),
                String.new(@whitespace.string)
            )

            @whitespace.string = ""

            return token
          else
            # @last_token_was_simple_value = true still
            return nil
          end
        else
          @last_token_was_simple_value = true
          @whitespace.string = ""
          return nil
        end
      end

    end

    # chars JSON allows a number to start with
    FIRST_NUMBER_CHARS = "0123456789-"
    # chars JSON allows to be part of a number
    NUMBER_CHARS = "0123456789eE+-."
    # chars that stop an unquoted string
    NOT_IN_UNQUOTED_TEXT = "$\"{}[]:=,+#`^?!@*&\\"

    def self.problem(origin, what, message, suggest_quotes, cause)
      if what.nil? || message.nil?
        throw Hocon::ConfigError::ConfigBugOrBrokenError.new("internal error, creating bad TokenizerProblemError", nil)
      end
      TokenizerProblemError.new(Tokens.new_problem(origin, what, message, suggest_quotes, cause))
    end

    def self.simple_value?(t)
      Tokens.substitution?(t) ||
          Tokens.unquoted_text?(t) ||
          Tokens.value?(t)
    end

    def self.whitespace?(c)
      Hocon::Impl::ConfigImplUtil.whitespace?(c)
    end

    def self.whitespace_not_newline?(c)
      (c != "\n") and (Hocon::Impl::ConfigImplUtil.whitespace?(c))
    end

    def_delegator :@tokens, :each

    def initialize(origin, input, allow_comments)
      @origin = origin
      @input = input
      @allow_comments = allow_comments
      @buffer = []
      @line_number = 1
      @line_origin = @origin.set_line_number(@line_number)
      @tokens = []
      @tokens << Tokens::START
      @whitespace_saver = WhitespaceSaver.new
    end

    def start_of_comment?(c)
      if c == -1
        false
      else
        if @allow_comments
          if c == '#'
            true
          elsif c == '/'
            maybe_second_slash = next_char_raw
            # we want to predictably NOT consume any chars
            put_back(maybe_second_slash)
            if maybe_second_slash == '/'
              true
            else
              false
            end
          end
        else
          false
        end
      end
    end

    def put_back(c)
      if @buffer.length > 2
        raise ConfigBugError, "bug: putBack() three times, undesirable look-ahead"
      end
      @buffer.push(c)
    end

    def next_char_raw
      if @buffer.empty?
        begin
          @input.readchar.chr
        rescue EOFError
          -1
        end
      else
        @buffer.pop
      end
    end

    def next_char_after_whitespace(saver)
      while true
        c = next_char_raw
        if c == -1
          return -1
        else
          if self.class.whitespace_not_newline?(c)
            saver.add(c)
          else
            return c
          end
        end
      end
    end

    # The rules here are intended to maximize convenience while
    # avoiding confusion with real valid JSON. Basically anything
    # that parses as JSON is treated the JSON way and otherwise
    # we assume it's a string and let the parser sort it out.
    def pull_unquoted_text
      origin = @line_origin
      io = StringIO.new
      c = next_char_raw
      while true
        if (c == -1) or
            (NOT_IN_UNQUOTED_TEXT.index(c)) or
            (self.class.whitespace?(c)) or
            (start_of_comment?(c))
          break
        else
          io << c
        end

        # we parse true/false/null tokens as such no matter
        # what is after them, as long as they are at the
        # start of the unquoted token.
        if io.length == 4
          if io.string == "true"
            return Tokens.new_boolean(origin, true)
          elsif io.string == "null"
            return Tokens.new_null(origin)
          end
        elsif io.length  == 5
          if io.string == "false"
            return Tokens.new_boolean(origin, false)
          end
        end

        c = next_char_raw
      end

      # put back the char that ended the unquoted text
      put_back(c)

      Tokens.new_unquoted_text(origin, io.string)
    end


    def pull_comment(first_char)
      if first_char == '/'
        discard = next_char_raw
        if discard != '/'
          raise ConfigBugError, "called pullComment but // not seen"
        end
      end

      io = StringIO.new
      while true
        c = next_char_raw
        if (c == -1) || (c == "\n")
          put_back(c)
          return Tokens.new_comment(@line_origin, io.string)
        else
          io << c
        end
      end
    end

    def pull_number(first_char)
      sb = StringIO.new
      sb << first_char
      contained_decimal_or_e = false
      c = next_char_raw
      while (c != -1) && (NUMBER_CHARS.index(c))
        if (c == '.') ||
            (c == 'e') ||
            (c == 'E')
          contained_decimal_or_e = true
        end
        sb << c
        c = next_char_raw
      end
      # the last character we looked at wasn't part of the number, put it
      # back
      put_back(c)
      s = sb.string
      begin
        if contained_decimal_or_e
          # force floating point representation
          Tokens.new_float(@line_origin, Float(s), s)
        else
          Tokens.new_long(@line_origin, Integer(s), s)
        end
      rescue ArgumentError => e
        if e.message =~ /^invalid value for (Float|Integer)\(\)/
          # not a number after all, see if it's an unquoted string.
          s.each_char do |u|
            if NOT_IN_UNQUOTED_TEXT.index(u)
              raise self.class.problem(@line_origin, u, "Reserved character '#{u}'" +
                "is not allowed outside quotes", true, nil)
            end
          end
          # no evil chars so we just decide this was a string and
          # not a number.
          Tokens.new_unquoted_text(@line_origin, s)
        else
          raise e
        end
      end
    end

    def pull_escape_sequence(sb)
      escaped = next_char_raw

      if escaped == -1
        error_msg = "End of input but backslash in string had nothing after it"
        raise self.class.problem(@line_origin, "", error_msg, false, nil)
      end

      case escaped
        when "\""
          sb << "\""
        when "\\"
          sb << "\\"
        when "/"
          sb << "/"
        when "b"
          sb << "\b"
        when "f"
          sb << "\f"
        when "n"
          sb << "\n"
        when "r"
          sb << "\r"
        when "t"
          sb << "\t"
        when "u"
          codepoint = ""

          # Grab the 4 hex chars for the unicode character
          4.times do
            c = next_char_raw

            if c == -1
              error_msg = "End of input but expecting 4 hex digits for \\uXXXX escape"
              raise self.class.problem(@line_origin, c, error_msg, false, nil)
            end

            codepoint << c
          end
          # Convert codepoint to a unicode character
          sb << [codepoint.hex].pack("U")

        else
          error_msg = "backslash followed by '#{escaped}', this is not a valid escape sequence (quoted strings use JSON escaping, so use double-backslash \\ for literal backslash)"
          raise self.class.problem(escaped, "", error_msg, false, nil)
      end
    end

    def append_triple_quoted_string(sb)
      # we are after the opening triple quote and need to consume the
      # close triple
      consecutive_quotes = 0

      while true
        c = next_char_raw

        if c == '"'
          consecutive_quotes += 1
        elsif consecutive_quotes >= 3
          # the last three quotes end the string and the other kept.
          sb.string = sb.string[0...-3]
          put_back c
          break
        else
          consecutive_quotes = 0
          if c == -1
            error_msg = "End of input but triple-quoted string was still open"
            raise self.class.problem(@line_origin, c, error_msg, false, nil)
          elsif c == "\n"
            # keep the line number accurate
            @line_number += 1
            @line_origin = @origin.set_line_number(@line_number)
          end
        end

        sb << c
      end
    end

    def pull_quoted_string
      # the open quote has already been consumed
      sb = StringIO.new
      c = ""
      while c != '"'
        c = next_char_raw
        if c == -1
          raise self.class.problem(@line_origin, c, "End of input but string quote was still open", false, nil)
        end

        if c == "\\"
          pull_escape_sequence(sb)
        elsif c == '"'
          # done!
        elsif c =~ /[[:cntrl:]]/
          raise self.class.problem(@line_origin, c, "JSON does not allow unescaped #{c}" +
                            " in quoted strings, use a backslash escape", false, nil)
        else
          sb << c
        end
      end

      # maybe switch to triple-quoted string, sort of hacky...
      if sb.length == 0
        third = next_char_raw
        if third == '"'
          append_triple_quoted_string(sb)
        else
          put_back(third)
        end
      end

      Tokens.new_string(@line_origin, sb.string)
    end

    def pull_plus_equals
      # the initial '+' has already been consumed
      c = next_char_raw

      unless c == '='
        error_msg = "'+' not followed by =, '#{c}' not allowed after '+'"
        raise self.class.problem(@line_origin, c, error_msg, true, nil) # true = suggest quotes
      end

      Tokens::PLUS_EQUALS
    end

    def pull_substitution
      # the initial '$' has already been consumed
      c = next_char_raw
      if c != '{'
        error_msg = "'$' not followed by {, '#{c}' not allowed after '$'"
        raise self.class.problem(@line_origin, c, error_msg, true, nil) # true = suggest quotes
      end

      optional = false
      c = next_char_raw

      if c == '?'
          optional = true
      else
          put_back(c)
      end

      saver = WhitespaceSaver.new
      expression = []

      while true
        t = pull_next_token(saver)
        # note that we avoid validating the allowed tokens inside
        # the substitution here; we even allow nested substitutions
        # in the tokenizer. The parser sorts it out.

        if t == Tokens::CLOSE_CURLY
          # end the loop, done!
          break
        elsif t == Tokens::EOF
          raise self.class.problem(@line_origin, t, "Substitution ${ was not closed with a }", false, nil)
        else
          whitespace = saver.check(t, @line_origin, @line_number)
          unless whitespace.nil?
            expression << whitespace
          end
          expression << t
        end
      end

      Tokens.new_substitution(@line_origin, optional, expression)
    end

    def pull_next_token(saver)
      c = next_char_after_whitespace(saver)
      if c == -1
        Tokens::EOF
      elsif c == "\n"
        # newline tokens have the just-ended line number
        line = Tokens.new_line(@line_origin)
        @line_number += 1
        @line_origin = @origin.set_line_number(@line_number)
        line
      else
        t = nil
        if start_of_comment?(c)
          t = pull_comment(c)
        else
          t = case c
                when '"' then pull_quoted_string
                when '$' then pull_substitution
                when ':' then Tokens::COLON
                when ',' then Tokens::COMMA
                when '=' then Tokens::EQUALS
                when '{' then Tokens::OPEN_CURLY
                when '}' then Tokens::CLOSE_CURLY
                when '[' then Tokens::OPEN_SQUARE
                when ']' then Tokens::CLOSE_SQUARE
                when '+' then pull_plus_equals
                else nil
              end

          if t.nil?
            if FIRST_NUMBER_CHARS.index(c)
              t = pull_number(c)
            elsif NOT_IN_UNQUOTED_TEXT.index(c)
              raise self.class.problem(@line_origin, c, "Reserved character '#{c}' is not allowed outside quotes", true, nil)
            else
              put_back(c)
              t = pull_unquoted_text
            end
          end
        end

        if t.nil?
          raise ConfigBugError, "bug: failed to generate next token"
        end

        t
      end
    end

    def queue_next_token
      t = pull_next_token(@whitespace_saver)
      whitespace = @whitespace_saver.check(t, @origin, @line_number)
      if whitespace
        @tokens.push(whitespace)
      end
      @tokens.push(t)
    end

    def next
      t = @tokens.shift
      if (@tokens.empty?) and (t != Tokens::EOF)
        begin
          queue_next_token
        rescue TokenizerProblemError => e
          @tokens.push(e.problem)
        end
        if @tokens.empty?
          raise ConfigBugError, "bug: tokens queue should not be empty here"
        end
      end
      t
    end

    def empty?
      @tokens.empty?
    end

    def has_next?
      !empty?
    end

    def each
      while has_next?
        # Have to use self.next instead of next because next is a reserved word
        yield self.next
      end
    end

    def map
      token_list = []
      each do |token|
        # yield token to calling method, append whatever is returned from the
        # map block to token_list
        token_list << yield(token)
      end

      token_list
    end

    def to_list
      # Return array of tokens from the iterator
      self.map { |token| token }
    end
  end


  def self.tokenize(origin, input, syntax)
    TokenIterator.new(origin, input, syntax != Hocon::ConfigSyntax::JSON)
  end
end
