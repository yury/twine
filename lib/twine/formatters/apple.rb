require 'Nokogiri'

module Twine
  module Formatters
    class Apple < Abstract
      def format_name
        'apple'
      end

      def extension
        '.strings'
      end

      def can_handle_directory?(path)
        Dir.entries(path).any? { |item| /^.+\.lproj$/.match(item) }
      end

      def default_file_name
        return 'Localizable.strings'
      end

      def determine_language_given_path(path)
        path_arr = path.split(File::SEPARATOR)
        path_arr.each do |segment|
          match = /^(.+)\.lproj$/.match(segment)
          if match
            if match[1] != "Base"
              return match[1]
            end
          end
        end

        return
      end

      def output_path_for_language(lang)
        "#{lang}.lproj"
      end

      def read(io, lang)
        uncategorized_section = nil
        if !section_exists('Uncategorized')
          uncategorized_section = TwineSection.new('Uncategorized')
          @twine_file.sections.insert(0, uncategorized_section)
        else
          uncategorized_section = get_section('Uncategorized')
        end
        last_comment = nil
        while line = io.gets
          # matches a `key = "value"` line, where key may be quoted or unquoted. The former may also contain escaped characters
          match = /^\s*((?:"(?:[^"\\]|\\.)+")|(?:[^"\s=]+))\s*=\s*"((?:[^"\\]|\\.)*)"/.match(line)
          if match
            key = match[1]
            key = key[1..-2] if key[0] == '"' and key[-1] == '"'
            key.gsub!('\\"', '"')
            value = match[2]
            value.gsub!('\\"', '"')
            value.gsub!('%s', '%@')
            value.gsub!('$s', '$@')
            set_translation_for_key(uncategorized_section, key, lang, value)
            if last_comment
              set_comment_for_key(key, last_comment)
            end
          end

          match = /\/\* (.*) \*\//.match(line)
          if match
            last_comment = match[1]
          else
            last_comment = nil
          end
        end

        # Handle plural files
        doc = File.open(plural_input_file_for_lang(lang)) { |f| Nokogiri::XML(f)}
        comment = nil
        key = nil
        value = nil

        top_level_dict = doc.css("dict").first
        whole_dicts = top_level_dict.xpath("./dict")
        plural_keys = top_level_dict.xpath("./key")

        for i in 0 ... whole_dicts.size do
          current_dict = whole_dicts[i]
          comment = current_dict.css("string").first.content
          key = plural_keys[i].content.to_s

          nested_dict = current_dict.xpath("./dict")
          nested_dict_keys = nested_dict.xpath("./key")
          nested_dict_strings = nested_dict.xpath("./string")

          section = nil
          if !section_exists(key)
            section = TwineSection.new(key)
            @twine_file.sections.insert(@twine_file.sections.size - 1, section)
          else
            section = get_section(key)
          end

          for j in 0 ... nested_dict_keys.children.size do
            cur_xml_key = nested_dict_keys.children[j]
            if !cur_xml_key.content.include? "NSString"
              modified_key = key + "__" + cur_xml_key.content.to_s

              set_translation_for_key(section, modified_key, lang, nested_dict_strings[j].content.to_s)
              set_ios_comment_for_key(modified_key, comment)
            end
          end
        end
      end

      def plural_input_file_for_lang(lang)
        @options[:input_path] + output_path_for_language(lang) + "/Localizable.stringsdict"
      end

      def plural_output_file_for_lang(lang)
        @options[:output_path] + output_path_for_language(lang) + "/Localizable.stringsdict"
      end

      def format_sections(twine_file, lang)
        first_plural = true
        out_file = File.new(plural_output_file_for_lang(lang), "w")

        sections = Array.new(twine_file.sections.size)
        for i in 0 ... twine_file.sections.size
          section = twine_file.sections[i]
          if section.name == 'Uncategorized'
            sections[i] = format_section(section, lang)
          else
            if first_plural
              first_plural = false
              out_file.puts(format_header_stringsdict)
            end
            format_section_plural(section, lang, out_file)
          end
        end
        out_file.puts(format_footer_stringsdict)
        out_file.close
        sections.compact.join("\n")
      end

      def format_section(section, lang)
        definitions = section.definitions.select { |definition| should_include_definition(definition, lang) }
        return if definitions.empty?

        result = ""

        if section.name && section.name.length > 0
          section_header = format_section_header(section)
          result += "\n#{section_header}" if section_header

          if section.name == 'Uncategorized'
            definitions.map! { |definition| format_definition(definition, lang) }
            definitions.compact! # remove nil definitions
            definitions.map! { |definition| "\n#{definition}" }  # prepend newline
            result += definitions.join
          end
        end
      end

      def format_section_plural(section, lang, out_file)
        for i in 0 ... section.definitions.size
          definition = section.definitions[i]
          value = definition.translation_for_lang(lang)
          comment = definition.ios_comment

          if comment == nil
            puts "Needs the iOS key matching the one in Localizable.string"
            return
          end

          if i == 0
            out_file.puts(format_plural_start(section.name, value, comment.to_s))
          end
          out_file.puts(format_plural_key(definition.key, value))
        end
        out_file.puts(format_plural_section_end)
      end

      ########### PLURALS START ###########

      def format_plural(definition, lang)
        [format_comment(definition, lang), format_key_value_plural_item(definition, lang)].compact.join
      end

      def format_key_value_plural_item(definition, lang)
        value = definition.translation_for_lang(lang)
        plurals_item_key_value_pattern(format_key(definition.key.dup), format_value(value.dup))
      end

      def format_header_stringsdict
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n" +
        "    <dict>\n"
      end

      def format_plural_start(section_name, key, comment)
        comment_parts = comment.split("@")

        # TODO: Should this be hardcoded or using Nokogiri somehow?
        "        <key>#{section_name}</key>\n" +
        "        <dict>\n" +
        "            <key>NSStringLocalizedFormatKey</key>\n" +
        "            <string>#{comment}</string>\n" +
        "            <key>#{comment_parts[1]}</key>\n" +
        "            <dict>\n" +
        "                <key>NSStringFormatSpecTypeKey</key>\n" +
        "                <string>NSStringPluralRuleType</string>\n" +
        "                <key>NSStringFormatValueTypeKey</key>\n" +
        "                <string>d</string>\n"
      end

      def format_plural_key(plural_key, plural_string)
        plural_key_parts = plural_key.rpartition(/.__/)
        # TODO: Nokogiri?
        "                <key>#{plural_key_parts[plural_key_parts.length - 1]}</key>\n" +
        "                <string>#{plural_string}</string>\n"
      end

      def format_plural_section_end
        # TODO: Nokogiri?
        "            </dict>\n" +
        "        </dict>\n"
      end

      def format_footer_stringsdict
        # TODO: Nokogiri?
        "    </dict>\n</plist>"
      end

      ########### PLURALS END ###########

      def format_header(lang)
        "/**\n * Apple Strings File\n * Generated by Twine #{Twine::VERSION}\n * Language: #{lang}\n */"
      end

      def format_section_header(section)
        "/********** #{section.name} **********/\n"
      end

      def key_value_pattern
        "\"%{key}\" = \"%{value}\";\n"
      end

      def format_comment(definition, lang)
        "/* #{definition.comment.gsub('*/', '* /')} */\n" if definition.comment
      end

      def format_key(key)
        escape_quotes(key)
      end

      def format_value(value)
        escape_quotes(value)
      end
    end
  end
end

Twine::Formatters.formatters << Twine::Formatters::Apple.new
