#!/usr/bin/env ruby
#
# flactagger - a program to tag FLAC files
# Copyright 2004,2005,2006,2007,2008 Tochiro <tochiroNO@SPAMusers.berlios.de>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


require 'optparse'

FTVERSION = "3.1.1"

Tag = Struct.new(:field, :value)
Options = Struct.new(:album, :combined_album, :date, :date_regexp, :edit, 
                     :dryrun, :help, :ifields, :infofile, :mode, :parser, 
                     :rtitles, :tags, :title_regexp, :ttype, :version,
                     :print)


class InfofileParser

  def initialize(filename)
    @data = IO.read(filename)
    @data = @data.gsub("\r\n", "\n").gsub("\r", "\n")
  end

  def headers
    return @data.split("\n\n")[0].split("\n")
  end

  def titles(re_title=/\d\d\. (.*)$/)
    lines = @data.split("\n")
    titles = []
    match = false
    pline = ""

    until lines.empty?
      line = lines.shift
      if line.match(re_title)
        titles << $1
        match = true
        pline = line
      elsif match
        # check for multi-line title
        # should be indented similar to match the start of the 
        # previous line's title
        #01. Title
        #   ^- space
        space = pline.index(" ")
        spaces = " " * space
        if line.index(spaces) == 0
          titles.last.concat(line.sub(spaces, ""))
        end
      else
        pline = ""
        match = false
      end
    end

    return titles
  end

  def map_headers_to_fields(fields)
    headers = self.headers
    tags = []
    fields.each do |field|
      tags.push(Tag.new(field, headers.shift))
    end

    return tags
  end

end


class FlacTagger
  
  def initialize(files, options)
    @files, @options = files, options
    @tags = {}
  end

  def FlacTagger.parse_options
    opts = Options.new(*[nil]*14)

    o = OptionParser.new
    o.summary_indent = " "
    o.summary_width = 14
    o.separator("")

    o.on("-A",
         "Use the ALBUM field rather than the default LOCATION field") do
      opts.album = true
    end

    o.on("-B",
         "Create ALBUM field combining the last LOCATION tag and the",
         "DATE field, e.g. 'City, Country. YYYY-MM-DD'") do
       opts.combined_album = true
    end

    o.on("-d", "=[REGEXP]",
         "Extract date from filenames. The optional argument is a",
         "Ruby regexp. If this is set it will be used to extract",
         "the date from filename.",
         "The default regexp is:  /(\\d{4}-\\d\\d-\\d\\d)/",
         "which corresponds to the ISO date format: YYYY-MM-DD") do |regexp|
      opts.date_regexp = (regexp==true) ? nil : eval(regexp)
      opts.date = true
    end

    o.on("-e",
         "Edit tags in an editor of your choice before tagging. Either the ",
         "VISUAL or EDITOR environment variable must be set") do
      opts.edit = true 
    end

    o.on("-f", "=FIELDLIST", Array,
         "Fields corresponding to lines from the top of the info file",
         "(comma separated). Note: cannot be used with the -m flag") do |fields|
      opts.ifields = fields
    end

    o.on("-i", "=INFOFILE",
         String,
         "Path to filename to be used as info file.") do |filename|
      opts.infofile = filename
    end

    o.on("-m", "=MODE", [:a, :b, :auto],
         "Parsing mode. Special modes for how to parse the header of info",
         "files. The header is assumed to be every line from the top of",
         "the info file until the first blank line. Available modes:",
         " a",
         "     ARTIST",
         "     LOCATION (multiple lines)",
         "     DATE (last line)",
         " b",
         "     ARTIST",
         "     DATE",
         "     LOCATION (all remaining lines)",
         " auto",
         "  try to detect mode 'a' or 'b' or fail") do |mode|
      opts.mode = mode
    end

    o.on("-n", "Dry run.") do 
      opts.dryrun = true 
    end

    o.on("-p", "Print file names while tagging.") do
      opts.print = true
    end

    o.on("-r", "=[REGEXP]",
         "Read titles from info file. The optional argument is a Ruby",
         "regexp. If this is set it will be used when scanning for ",
         "titles in the info file. If not the default will be used ",
         "which is: /^\\d\\d\\. (.*)$/") do |regexp|
      opts.rtitles = true
      opts.title_regexp = (regexp==true) ? nil : eval(regexp)
    end

    o.on("-t", "=TAG", String,
         "Add a TAG which is a field/value pair (FIELD=Value). This",
         "option can be used multiple times.") do |tag|
      field,value = tag.split("=")
      opts.tags = [] if opts.tags.nil?
      opts.tags << Tag.new(field,value)
    end

    o.on("-T", "=TYPE", [:a, :b, :c],
         "Track number type a, b or d",
         "  a = use dNtNN from filename or just tNN without 't' if no 'd'",
         "  b = same as a except exclude 'd' and 't' (d1t02 becomes 102)",
         "  c = generate track number(s) from 01") do |ttype|
      opts.ttype = ttype
    end

    o.on_tail("-v", "Show version") do
      opts.version = true
    end

    o.on_tail("-h", "Help") do
      opts.help = true
    end

    if ARGV.empty?
      puts o.help
      exit(1)
    else
      begin
        o.parse!(ARGV)
      rescue Exception => e
        $stderr << e.message << "\n"
        $stderr << e.backtrace.join("\n") << "\n" if $DEBUG
        exit(1)
      end
    end

    if opts.help
      puts o.help
      exit(0)
    elsif opts.version
      puts FTVERSION
      exit(0)
    end

    files = []
    
    ARGV.each do |arg|
      if File.exists?(arg)
        files << arg
      else
        $stderr.write("Unknown options: %s\n" % arg)
        exit(1)
      end
    end
    
    return opts, files
  end

  def FlacTagger.invoke
    options, files = parse_options
    FlacTagger.new(files, options).invoke
  end

  def create_metaflac_args(tags)
    args = []
    args.push("--remove-all-tags")
    args.push("--no-utf8-convert")

    tags.each do |tag|
      args << '--set-tag=%s=%s' % [tag.field,tag.value]
    end

    return args
  end

  def tag(dryrun=false, print=false)
    @tags.sort.each do |filename, tags|
      if print
        puts "%s" % filename
      end
      unless dryrun
        unless system("metaflac", 
                      *create_metaflac_args(sort_tags(tags)).push(filename))
          $stderr.write("%s FAILED\n" % filename)
          exit(1)
        end
      else
        puts "%s:" % filename
        sort_tags(tags).each do |tag|
          puts "  %s=%s" % [ tag.field, tag.value ]
        end
      end
    end
  end

  def sort_tags(tags)
    tags.sort do |x,y|
      if x.field == y.field
        0
      elsif x.field < y.field
        -1
      else
        1
      end
    end
  end

  def extract_dates(filenames)
    dates = []

    filenames.each do |filename|
      if @options.date_regexp and filename.match(@options.date_regexp)
        dates << $1
      elsif filename.match(/(\d{4}-\d\d-\d\d)/)
        dates << $1
      else
        raise "Unable to extract date from: %s" % filename
      end
    end

    return dates
  end

  def parse_info_file(infofile, rtitles, title_regexp, mode, 
                      ifields, use_album, combined_album)
    titles = []
    tags = []
    
    if File.exists?(infofile)
      ifp = InfofileParser.new(infofile)
      if rtitles
        titles = if title_regexp
                   ifp.titles(title_regexp).flatten
                 else
                   ifp.titles.flatten
                 end
      end
      if mode
        case mode
        when :a
          headers = ifp.headers
          artist = headers.shift
          date = headers.pop
          locations = headers
          tags << Tag.new("ARTIST", artist)
          tags << Tag.new("DATE", date)
          unless use_album
            locations.each { |l| tags << Tag.new("LOCATION", l) }
          else
            locations.each { |l| tags << Tag.new("ALBUM", l) }
          end
          if combined_album
            tags << Tag.new("ALBUM", "#{locations.last}. #{date}")
          end
        when :b
          headers = ifp.headers
          artist = headers.shift
          date = headers.shift
          locations = headers
          tags << Tag.new("ARTIST", artist)
          tags << Tag.new("DATE", date)
          unless use_album
            locations.each { |l| tags << Tag.new("LOCATION", l) }
          else
            locations.each { |l| tags << Tag.new("ALBUM", l) }
          end
          if combined_album
            tags << Tag.new("ALBUM", "#{locations.last}. #{date}")
          end
        when :auto
          headers = ifp.headers

          if headers[1].match(/\d{4}-\d\d-\d\d/)
            return parse_info_file(infofile, rtitles, title_regexp, 
                                   :b, ifields, use_album, combined_album)
          elsif headers.last.match(/\d{4}-\d\d-\d\d/)
            return parse_info_file(infofile, rtitles, title_regexp, 
                                   :a, ifields, use_album, combined_album)
          else
            raise "Unable to automatically detect mode"
          end
        else
          raise "No such mode: %s" % options.mode
        end
      elsif ifields
        tags.concat(ifp.map_headers_to_fields(ifields))
      end
    else
      raise "%s does not exist" % infofile
      exit(1)
    end

    return tags, titles
  end

  def extract_tracknumbers(filenames, ttype)
    tracknumbers = []

    case ttype
    when :a
      filenames.each do |filename|
        if filename.match(/-.*(d\d+t\d+)/)
          tracknumbers << $1
        elsif filename.match(/-.*t(\d+)\./)
          tracknumbers << $1
        else
          raise "Could not extract track number for %s" % filename
        end
      end
    when :b
      filenames.each do |filename|
        if filename.match(/d(\d+)t(\d+)/)
          tracknumbers << "%s%s" % [$1, $2]
        else
          raise "Could not extract track number for %s (ttype=%s)" % 
            [
             filename,
             ttype
            ]
        end
      end
    when :c
      "1".upto(filenames.length.to_s) do |i| 
        if filenames.length < 10
          tracknumbers << "0%s" % i
        else
          tracknumbers << i.rjust(filenames.length.to_s.length, "0")
        end
      end
    end

    return tracknumbers
  end

  def write_tags_file(gtags, ftags)
    File.open(".tags", "w") do |f|
      f.write("# Format: \n" \
              "# GLOBAL FIELD=Value\n"\
              "# GLOBAL FIELD2=Value2\n"\
              "# GLOBAL FIELD3=Value3\n"\
              "# filename1.flac:\n"\
              "#   FIELD1=Value1\n"\
              "#   FIELD2=Value2\n"\
              "#   FIELD3=Value3\n"\
              "# /path/filename2.flac:\n"\
              "#   FIELD1=Value1\n"\
              "#   FIELD2=Value2\n"\
              "#   FIELD3=Value3\n"\
              "#\n"\
              "# The two spaces before FIELD/Value pairs are important!\n"\
              "# Blank lines or lines starting with # are ignored\n"\
              "#\n\n")

      if gtags
        gtags.each do |t|
          f.write("GLOBAL %s=%s\n" % [ t.field, t.value ])
        end
        f.write("\n")
      end
      if ftags
        ftags.sort.each do |filename, tags|
          f.write("%s:\n" % filename)
          tags.each do |t|
            f.write("  %s=%s\n" % [ t.field, t.value ])
          end
        end
        f.write("\n")
      end
    end
  end

  def parse_tags_file
    cfile = nil
    tags = []

    File.open(".tags", "r") do |f|
      lines = f.read.split("\n")
      lines.each do |line|
        next if line.match(/^\#|^[ ]*$/)

        if line.match(/^GLOBAL (.*)=(.*)$/)
          add_global_tag($1.strip, $2.strip)
        elsif line.match(/^(.*):$/)
          file = $1.strip
          if cfile.nil?
            cfile = file
          else
            tags.each do |f,v|
              add_tag(cfile, f, v)
            end
            tags.clear
            cfile = file
          end
        elsif line.match(/^  (.*)=(.*)$/)
          tags << [$1.strip, $2.strip]
        end
      end
      
      if cfile and tags
        tags.each do |f,v|
          add_tag(cfile, f, v)
        end
      end
    end
  end


  def add_global_tag(field, value)
    @files.each do |filename|
      add_tag(filename, field, value)
    end
  end


  def add_tag(filename, field, value)
    if @tags.key?(filename)
      @tags[filename] << Tag.new(field, value)
    else
      @tags[filename] = [ Tag.new(field, value) ]
    end
  end

  def edit_tags(gtags, ftags)
    editor = ENV["EDITOR"] || ENV["VISUAL"] || nil
    
    if editor
      if write_tags_file(gtags, ftags)
        if system(editor, ".tags")
          begin
            parse_tags_file
          rescue Exception => e
            $stderr.write(e.message + "\n")
          end
        else
          $stderr.write("Editing failed???\n")
        end
      else
        raise("Neither of the environment variables VISUAL or"\
              "EDITOR are set. Needed with -e.")
      end
    end

    File.unlink(".tags") if File.exists?(".tags")
  end


  def collect_replay_gain(files)
    rgain = {}

    files.each do |filename|
      tagsfile = "#{filename}.tags"
      ret = system("metaflac",
                   "--export-tags-to=#{tagsfile}",
                   filename)

      raise "Error occured trying to run 'metaflac'" unless ret
      
      IO.readlines(tagsfile).each do |line|
        tag,value = line.strip.split("=")

        if tag.match(/REPLAYGAIN/)
          if rgain.key?(filename)
            rgain[filename] << Tag.new(tag, value)
          else
            rgain[filename] = [ Tag.new(tag, value) ]
          end
        end
      end

      File.unlink(tagsfile)
    end

    return rgain
  end

  def invoke
    dates, gtags, titles, tracknumbers = [], [], [], []

    gtags, titles = parse_info_file(@options.infofile,
                                    @options.rtitles,
                                    @options.title_regexp,
                                    @options.mode,
                                    @options.ifields,
                                    @options.album,
                                    @options.combined_album) if @options.infofile

    dates = array_to_tags(extract_dates(@files), 
                          "DATE") if @options.date
    tracknumbers = array_to_tags(extract_tracknumbers(@files,
                                                      @options.ttype),
                                 "TRACKNUMBER") if @options.ttype

    titles = array_to_tags(titles, "TITLE") if @options.rtitles

    gtags.concat(@options.tags) if @options.tags

    replaygain = collect_replay_gain(@files)

    ftags = associate_files_with_tags(@files,
                                      dates,
                                      titles,
                                      tracknumbers,
                                      replaygain)

    if @options.edit
      edit_tags(gtags, ftags)
    else
      gtags.each do |tag| 
        add_global_tag(tag.field, tag.value)
      end if gtags

      ftags.each do |fname, tags| 
        tags.each { |t| add_tag(fname, t.field, t.value) } 
      end if ftags
    end
    
    tag(@options.dryrun, @options.print)
  end

  def associate_files_with_tags(files, dates, tracknumbers, titles, rgain)
    tagshash = {}

    fl = files.length

    if fl != dates.length 
      unless dates.nil? or dates.empty?
        raise "Number of files is not equal to the number of extracted dates"
      end
    elsif fl != tracknumbers.length
      unless tracknumbers.nil? or tracknumbers.empty?
        raise "Number of files is not equal to the number of track numbers"
      end
    elsif fl != titles.length
      unless titles.nil? or titles.empty?
        raise "Number of files is not equal to the number of titles"
      end
    end

    files.each do |filename|
      all_tags = []
      all_tags << dates.shift unless dates.nil? or dates.empty?
      all_tags << tracknumbers.shift unless tracknumbers.nil? or
        tracknumbers.empty?
      all_tags << titles.shift unless titles.nil? or titles.empty?

      if rgain.key?(filename)
        rgain[filename].each do |rgain_tag|
          all_tags << rgain_tag
        end
      end

      unless all_tags.empty?
        all_tags.sort! { |x,y| x.field<=>y.field }
      end

      tagshash[filename] = all_tags
    end

    return tagshash
  end

  def array_to_tags(a, field)
    tags = []
    a.each do |i|
      tags << Tag.new(field, i)
    end

    return tags
  end

end


begin
  FlacTagger.invoke
rescue SystemExit => e
  exit(e.status)
rescue Exception => e
  $stderr << e.class << "\n" if $DEBUG
  $stderr << e.message << "\n"
  $stderr << e.backtrace.join("\n") << "\n" if $DEBUG
  exit(1)
else
  exit(0)
end
