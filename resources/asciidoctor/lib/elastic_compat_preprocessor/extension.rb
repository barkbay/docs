# frozen_string_literal: true

require 'asciidoctor/extensions'

require_relative '../migration_log'

##
# Preprocessor to turn Elastic's "wild west" formatted block extensions into
# standard asciidoctor formatted extensions
#
# Turns
#   added[6.0.0-beta1]
#   coming[6.0.0-beta1]
#   deprecated[6.0.0-beta1]
# Into
#   added::[6.0.0-beta1]
#   coming::[6.0.0-beta1]
#   deprecated::[6.0.0-beta1]
# Because `::` is required by asciidoctor to invoke block macros but isn't
# required by asciidoc.
#
# Turns
#   words words added[6.0.0-beta1]
#   words words changed[6.0.0-beta1]
#   words words deprecated[6.0.0-beta1]
# Into
#   words words added:[6.0.0-beta1]
#   words words changed:[6.0.0-beta1]
#   words words deprecated:[6.0.0-beta1]
# Because `:` is required by asciidoctor to invoke inline macros but isn't
# required by asciidoc.
#
# Turns
#   include-tagged::foo[tag]
# Into
#   include::elastic-include-tagged:foo[tag]
# To chain into the ElasticIncludeTagged processor which is *slightly* different
# than asciidoctor's built in tagging support.
#
# Turns
#   --
#   :api: bulk
#   :request: BulkRequest
#   :response: BulkResponse
#   --
# Into
#   :api: bulk
#   :request: BulkRequest
#   :response: BulkResponse
# Because asciidoctor clears attributes set in a block. See
# https://github.com/asciidoctor/asciidoctor/issues/2993
#
# Turns
#   ["source","sh",subs="attributes"]
#   --------------------------------------------
#   wget https://artifacts.elastic.co//elasticsearch-{version}.zip
#   wget https://artifacts.elastic.co//elasticsearch-{version}.zip.sha512
#   shasum -a 512 -c elasticsearch-{version}.zip.sha512 <1>
#   unzip elasticsearch-{version}.zip
#   cd elasticsearch-{version}/ <2>
#   --------------------------------------------
#   <1> Compares the SHA of the downloaded `.zip` archive and the published
#       checksum, which should output `elasticsearch-{version}.zip: OK`.
#   <2> This directory is known as `$ES_HOME`.
#
# Into
#   ["source","sh",subs="attributes,callouts"]
#   --------------------------------------------
#   wget https://artifacts.elastic.co/elasticsearch-{version}.zip
#   wget https://artifacts.elastic.co/elasticsearch-{version}.zip.sha512
#   shasum -a 512 -c elasticsearch-{version}.zip.sha512 <1>
#   unzip elasticsearch-{version}.zip
#   cd elasticsearch-{version}/ <2>
#   --------------------------------------------
#   <1> Compares the SHA of the downloaded `.zip` archive and the published
#       checksum, which should output `elasticsearch-{version}.zip: OK`.
#   <2> This directory is known as `$ES_HOME`.
# Because asciidoc adds callouts to all "source" blocks. We'd *prefer* to do
# this in the tree processor because it is less messy but we can't because
# asciidoctor checks the `:callout` sub before giving us a chance to add it.
#
# Turns
#   ----
#   foo
#   ------
#
# Into
#   ----
#   foo
#   ----
# Because Asciidoc permits these mismatches but asciidoctor does not. We'll
# emit a warning because, permitted or not, they are bad style.
#
# With the help of ElasticCompatTreeProcessor turns
#   [source,js]
#   ----
#   foo
#   ----
#   // CONSOLE
#
# Into
#   [source,console]
#   ----
#   foo
#   ----
# Because Elastic has thousands of these constructs but Asciidoctor feels
# strongly that comments should not convey meaning. This is a totally
# reasonable stance and we should migrate away from these comments in new
# docs when it is possible. But for now we have to support the comments as
# well.
#
class ElasticCompatPreprocessor < Asciidoctor::Extensions::Preprocessor
  INCLUDE_TAGGED_DIRECTIVE_RX =
    /^include-tagged::([^\[][^\[]*)\[(#{Asciidoctor::CC_ANY}+)?\]$/
  SOURCE_WITH_SUBS_RX =
    /^\["source", ?"[^"]+", ?subs="(#{Asciidoctor::CC_ANY}+)"\]$/
  CODE_BLOCK_RX = /^-----*$/
  SNIPPET_RX = %r{^//\s*(AUTOSENSE|KIBANA|CONSOLE|SENSE:[^\n<]+)$}
  LEGACY_MACROS = 'added|beta|coming|deprecated|experimental'
  LEGACY_BLOCK_MACRO_RX = /^\s*(#{LEGACY_MACROS})\[(.*)\]\s*$/
  LEGACY_INLINE_MACRO_RX = /(#{LEGACY_MACROS})\[(.*)\]/

  def process(_document, reader)
    reader.extend ReaderExtension
  end

  ##
  # Extensions to the Reader object that implement the conversions.
  module ReaderExtension
    def self.extended(base)
      base.extend MigrationLog
      base.instance_variable_set :@in_attribute_only_block, false
      base.instance_variable_set :@code_block_start, nil
    end

    ##
    # Replaces the Asciidoctor's built in line processing to do our conversion.
    def process_line(line)
      return line unless @process_lines

      if @in_attribute_only_block
        process_in_attribute_only_block line
      elsif line == '--'
        process_start_block line
      elsif (match = INCLUDE_TAGGED_DIRECTIVE_RX.match line)
        process_include_tagged line, match[1], match[2]
      else
        postprocess super
      end
    end

    ##
    # Handle a line if we're in attribute only block. We are basically a
    # passthrough in this state, just hunting for the block end. If we hit the
    # block end we eat the block delimiter because we ate the start delimiter
    # when entering into the attribute only block.
    def process_in_attribute_only_block(line)
      return line unless line == '--'

      @in_attribute_only_block = false
      line.clear
    end

    ##
    # Process a start block when, potentially shifting into the "attribute only"
    # block state if the block that is starting only contains attributes. If
    # we enter into that state then we eat the block delimiter to work around
    # a scoping difference between AsciiDoc and Asciidoctor.
    def process_start_block(line)
      lines = self.lines
      lines.shift

      lines.shift while Asciidoctor::AttributeEntryRx =~ lines[0]
      return line unless lines.shift == '--'

      @in_attribute_only_block = true
      line.clear
    end

    ##
    # Process the `include-tagged` directive.
    def process_include_tagged(line, target, tag)
      return if preprocess_include_directive(
        "elastic-include-tagged:#{target}", tag
      )

      # the line was not a valid include line and we've logged a warning
      # about it so we should do the asciidoctor standard thing and keep
      # it intact. This is how we do that.
      @look_ahead += 1
      line
    end

    ##
    # Process lines after they've been processed by the reader.
    def postprocess(line)
      return unless line

      # We can't modify frozen strings anyway *and* they never contain any
      # of the markers that we care about.
      return if line.frozen?

      fix_subs line
      fix_code_block_delimiters line

      # First convert the "block" version of these macros. We convert them
      # to block macros because they are alone on a line
      line.gsub!(LEGACY_BLOCK_MACRO_RX, '\1::[\2]')
      # Then convert the "inline" version of these macros. We convert them
      # to inline macros because they are *not* at the start of the line....
      line.gsub!(LEGACY_INLINE_MACRO_RX, '\1:[\2]')

      # Transform Elastic's traditional comment based marking for
      # AUTOSENSE/KIBANA/CONSOLE snippets into a marker that we can pick
      # up during tree processing to turn the snippet into a marked up
      # CONSOLE snippet. Asciidoctor really doesn't recommend this sort of
      # thing but we have thousands of them and it'll take us some time to
      # stop doing it.
      line.gsub!(SNIPPET_RX, 'lang_override::[\1]')
    end

    def fix_subs(line)
      SOURCE_WITH_SUBS_RX.match(line) do |m|
        # AsciiDoc would automatically add `subs` to every source block but
        # Asciidoctor does not and we have thousands of blocks that rely on
        # this behavior.
        old_subs = m[1]
        line.sub! "subs=\"#{old_subs}\"", "subs=\"#{old_subs},callouts\"" \
          unless old_subs.include? 'callouts'
      end
    end

    def fix_code_block_delimiters(line)
      return unless CODE_BLOCK_RX =~ line

      unless @code_block_start
        @code_block_start = line
        return
      end

      if line != @code_block_start
        line.replace @code_block_start
        migration_warn @document, cursor, 'delimiter-mismatch',
                       "code block end doesn't match start"
      end
      @code_block_start = nil
    end
  end
end
