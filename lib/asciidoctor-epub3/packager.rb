require_relative 'core_ext/string'
autoload :FileUtils, 'fileutils'
autoload :Open3, 'open3'
autoload :Shellwords, 'shellwords'

module Asciidoctor
module Epub3
module GepubBuilderMixin
  DATA_DIR = ::File.expand_path(::File.join ::File.dirname(__FILE__), '..', '..', 'data')
  SAMPLES_DIR = ::File.join DATA_DIR, 'samples'
  WordJoiner = Converter::WordJoiner
  FromHtmlSpecialCharsMap = Converter::FromHtmlSpecialCharsMap
  FromHtmlSpecialCharsRx = Converter::FromHtmlSpecialCharsRx
  DefaultCoverImage = 'images/default-cover.png'
  InlineImageMacroRx = /^image:(.*?)\[(.*?)\]$/

  def sanitized_doctitle doc, target = :plain
    title = case target
    when :attribute_cdata
      doc.doctitle(sanitize: true).gsub('"', '&quot;')
    when :element_cdata
      doc.doctitle sanitize: true
    when :pcdata
      doc.doctitle
    when :plain
      doc.doctitle(sanitize: true).gsub(FromHtmlSpecialCharsRx, FromHtmlSpecialCharsMap)
    end
    title.gsub WordJoiner, ''
  end

  def add_theme_assets doc
    builder = self
    format = @format
    resources workdir: DATA_DIR do
      # TODO support custom theme
      file 'styles/epub3.css' => (builder.postprocess_css_file 'styles/epub3.css', format)
      font_list, font_css = builder.select_fonts 'styles/epub3-fonts.css', (doc.attr 'scripts', 'latin')
      file 'styles/epub3-fonts.css' => font_css
      file 'styles/epub3-css3-only.css' => (builder.postprocess_css_file 'styles/epub3-css3-only.css', format)
      with_media_type 'application/x-font-ttf' do
        files(*font_list)
      end
    end
  end

  def add_cover_image doc
    imagesdir = (doc.attr 'imagesdir', '.').chomp '/'
    imagesdir = (imagesdir == '.' ? nil : %(#{imagesdir}/))

    if (front_cover_image = doc.attr 'front-cover-image')
      if front_cover_image =~ InlineImageMacroRx
        front_cover_image = %(#{imagesdir}#{$1})
      end
      workdir = doc.attr 'docdir'
    else
      front_cover_image = DefaultCoverImage
      workdir = DATA_DIR
    end

    resources workdir: workdir do
      cover_image %(#{imagesdir}jacket/cover#{::File.extname front_cover_image}) => front_cover_image
    end
  end

  # NOTE must be called within the ordered block
  def add_cover_page doc, spine_builder, book
    imagesdir = (doc.attr 'imagesdir', '.').chomp '/'
    imagesdir = (imagesdir == '.' ? nil : %(#{imagesdir}/))

    img = (doc.attr 'front-cover-image') || DefaultCoverImage

    if img =~ InlineImageMacroRx
      img = %(#{imagesdir}#{$1})
      # TODO use proper attribute parser
      _, w, h = $2.split ',', 3
    end

    w ||= 1050
    h ||= 1600
    img_path = %(#{imagesdir}jacket/cover#{::File.extname img})
    # NOTE SVG wrapper maintains aspect ratio and confines image to view box
    content = %(<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
<head>
<meta charset="UTF-8"/>
<title>#{sanitized_doctitle doc, :element_cdata}</title>
<style type="text/css">
@page {
  margin: 0;
}
html {
  margin: 0 !important;
  padding: 0 !important;
}
body {
  margin: 0;
  padding: 0 !important;
  text-align: center;
}
body > svg {
  /* prevent bleed onto second page (removes descender space) */
  display: block;
}
</style>
</head>
<body epub:type="cover"><svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
  width="100%" height="100%" viewBox="0 0 #{w} #{h}" preserveAspectRatio="xMidYMid meet">
<image width="#{w}" height="#{h}" xlink:href="#{img_path}"/>
</svg></body>
</html>).to_ios
    # GitDen expects a cover.xhtml, so add it to the spine
    spine_builder.file 'cover.xhtml' => content
    spine_builder.id 'cover'
    # clearly a deficiency of gepub that it does not match the id correctly
    book.spine.itemref_by_id['item_cover1'].idref = 'cover'
  end

  # FIXME don't add same image more than once
  # FIXME add inline images
  def add_content_images doc, images
    docimagesdir = (doc.attr 'imagesdir', '.').chomp '/'
    docimagesdir = (docimagesdir == '.' ? nil : %(#{docimagesdir}/))

    resources workdir: doc.attr('docdir') do
      images.each do |image|
        imagesdir = (image.document.attr 'imagesdir', '.').chomp '/'
        imagesdir = (imagesdir == '.' ? nil : %(#{imagesdir}/))
        image_path = %(#{imagesdir}#{image.attr 'target'})
        if image_path.start_with? %(#{docimagesdir}jacket/cover.)
          warn %(The image path #{image_path} is reserved for the cover artwork. Ignoring conflicting image from content.)
        elsif ::File.readable? image_path
          file image_path
        else
          warn %(Image not found or not readable: #{image_path})
        end
      end
    end
  end

  def add_avatar_images doc, usernames
    imagesdir = (doc.attr 'imagesdir', '.').chomp '/'
    imagesdir = (imagesdir == '.' ? nil : %(#{imagesdir}/))

    resources workdir: DATA_DIR do
      file %(#{imagesdir}avatars/default.png) => %(images/default-avatar.png)
    end

    resources workdir: doc.attr('docdir') do
      usernames.each do |username|
        if ::File.readable?(avatar = %(#{imagesdir}avatars/#{username}.png))
          file avatar
        else
          warn %(Avatar #{avatar} not found or not readable. Falling back to default avatar for #{username}.)
          ::Dir.chdir DATA_DIR do
            file avatar => %(images/default-avatar.png)
          end
        end
      end
    end
  end

  def add_content doc
    builder = self
    spine = @spine
    format = @format
    resources workdir: doc.attr('docdir') do
      # QUESTION should we move navigation_document to the Packager class? seems to make sense
      nav 'nav.xhtml' => (builder.postprocess_xhtml doc.converter.navigation_document(doc, spine), format)
      ordered do
        builder.add_cover_page doc, self, @book unless format == :kf8
        spine.each_with_index do |item, i|
          content_path = %(#{item.attr 'docname'}.xhtml)
          file content_path => (builder.postprocess_xhtml item.convert, format)
          # NOTE heading for ePub2 navigation file; toc.ncx requires headings to be plain text
          heading builder.sanitized_doctitle(item)
          @last_defined_item.properties << 'svg' if ((item.attr 'epub-properties') || []).include? 'svg'
          #linear 'yes' if i == 0
        end
      end
    end
  end

  # Swap fonts in CSS based on the value of the document attribute 'scripts',
  # then return the list of fonts as well as the font CSS.
  def select_fonts filename, scripts = 'latin'
    font_css = ::File.read(filename)
    font_css = font_css.gsub(/(?<=-)latin(?=\.ttf\))/, scripts) unless scripts == 'latin'
    font_list = font_css.scan(/url\(\.\.\/(.+\.ttf)\);$/).flatten
    return [font_list, font_css.to_ios]
  end

  def postprocess_css_file filename, format
    return filename unless format == :kf8
    postprocess_css ::File.read(filename), format
  end

  def postprocess_css content, format
    return content.to_ios unless format == :kf8
    # TODO convert regular expressions to constants
    content
        .gsub(/^  -webkit-column-break-.*\n/, '')
        .gsub(/^  max-width: .*\n/, '')
        .to_ios
  end

  def postprocess_xhtml_file filename, format
    return filename unless format == :kf8
    postprocess_xhtml ::File.read(filename), format
  end

  # NOTE Kindle requires that
  #      <meta charset="utf-8"/>
  #      be converted to
  #      <meta http-equiv="Content-Type" content="application/xml+xhtml; charset=UTF-8"/>
  def postprocess_xhtml content, format
    return content.to_ios unless format == :kf8
    # TODO convert regular expressions to constants
    content
        .gsub(/<meta charset="(.+?)"\/>/, '<meta http-equiv="Content-Type" content="application/xml+xhtml; charset=\1"/>')
        .gsub(/<img([^>]+) style="width: (\d\d)%;"/, '<img\1 style="width: \2%; height: \2%;"')
        .gsub(/<script type="text\/javascript">.*?<\/script>\n?/m, '')
        .to_ios
  end
end

class Packager
  KINDLEGEN = ENV['KINDLEGEN'] || 'kindlegen'
  EPUBCHECK = ENV['EPUBCHECK'] || %(epubcheck#{::Gem.win_platform? ? '.bat' : '.sh'})
  CsvDelimiterRx = /\s*,\s*/
  EpubExtensionRx = /\.epub$/
  Kf8ExtensionRx = /-kf8\.epub$/

  def initialize master_doc, spine, dest_dir, format = :epub3, options = {}
    @document = master_doc
    @spine = spine || []
    @dest_dir = dest_dir
    @format = format
  end

  def package options = {}
    doc = @document
    spine = @spine
    fmt = @format
    dest = @dest_dir

    images = spine.map {|item| (item.find_by :image) || [] }.flatten
    usernames = spine.map {|item| item.attr 'username' }.compact.uniq
    # FIXME authors should be aggregated already on parent document
    authors = (doc.attr 'authors').split(CsvDelimiterRx).concat(spine.map {|item| item.attr 'author' }).uniq

    builder = ::GEPUB::Builder.new do
      extend GepubBuilderMixin
      @document = doc
      @spine = spine
      @format = fmt
      @book.epub_backward_compat = (fmt != :kf8)

      language(doc.attr 'lang', 'en')
      id 'pub-language'

      unique_identifier doc.id, 'pub-identifier', 'uuid'
      # replace with next line once the attributes argument is supported
      #unique_identifier doc.id, 'pub-id', 'uuid', 'scheme' => 'xsd:string'

      title sanitized_doctitle(doc)
      id 'pub-title'

      if doc.attr? 'producer'
        producer = doc.attr 'producer'
        if doc.attr? 'creator'
          # marc role: Creator (see http://www.loc.gov/marc/relators/relaterm.html)
          creator doc.attr('creator'), 'cre'
        else
          # marc role: Book producer
          creator producer, 'bkp'
        end
        publisher producer
      else
        if doc.attr? 'author'
          # marc role: Author
          creator doc.attr('author'), 'aut'
        else
          # marc role: Provider
          creator 'Asciidoctor', 'prv'
        end
      end

      # TODO getting author list should be a method on Asciidoctor API
      contributors(*authors)

      if doc.attr? 'revdate'
        # TODO ensure this is a real date
        date(doc.attr 'revdate')
      else
        date ::Time.now.strftime('%Y-%m-%dT%H:%M:%SZ')
      end

      if doc.attr? 'description'
        description(doc.attr 'description')
      end

      if doc.attr? 'keywords'
        (doc.attr 'keywords').split(CsvDelimiterRx).each do |s|
          subject s
        end
      end

      if doc.attr? 'source'
        source(doc.attr 'source')
      end

      if doc.attr? 'copyright'
        rights(doc.attr 'copyright')
      end

      add_theme_assets doc
      add_cover_image doc
      add_avatar_images doc, usernames
      # QUESTION move add_content_images to add_content method?
      add_content_images doc, images
      add_content doc
    end

    ::FileUtils.mkdir_p dest unless ::File.directory? dest

    epub_file = ::File.expand_path %(#{doc.attr 'docname'}#{fmt == :kf8 ? '-kf8' : nil}.epub), dest
    builder.generate_epub epub_file
    puts %(Wrote #{fmt.upcase} to #{epub_file})
    if options[:extract]
      extract_dir = epub_file.sub EpubExtensionRx, ''
      ::FileUtils.remove_dir extract_dir if ::File.directory? extract_dir
      ::Dir.mkdir extract_dir
      ::Dir.chdir extract_dir do
        ::Zip::File.open epub_file do |entries|
          entries.each do |entry|
            next unless entry.file?
            unless (entry_dir = ::File.dirname entry.name) == '.' || (::File.directory? entry_dir)
              ::FileUtils.mkdir_p entry_dir
            end
            entry.extract
          end
        end
      end
      puts %(Extracted #{fmt.upcase} to #{extract_dir})
    end

    if fmt == :kf8
      distill_epub_to_mobi epub_file
    elsif options[:validate]
      validate_epub epub_file
    end
  end

  # QUESTION how to enable the -c2 flag? (enables ~3-5% compression)
  def distill_epub_to_mobi epub_file
    kindlegen_cmd = KINDLEGEN
    unless ::File.executable? kindlegen_cmd
      require 'kindlegen' unless defined? ::Kindlegen
      kindlegen_cmd = ::Kindlegen.command
    end
    mobi_file = ::File.basename(epub_file).sub Kf8ExtensionRx, '.mobi'
    ::Open3.popen2e(Shellwords.join [kindlegen_cmd, '-o', mobi_file, epub_file]) {|input, output, wait_thr|
      output.each {|line| puts line }
    }
    puts %(Wrote MOBI to #{::File.join ::File.dirname(epub_file), mobi_file})
  end

  def validate_epub epub_file
    epubcheck_cmd = EPUBCHECK
    unless ::File.executable? epubcheck_cmd
      epubcheck_cmd = ::Gem.bin_path 'epubcheck', 'epubcheck' 
    end
    # NOTE epubcheck gem doesn't support epubcheck command options; enable -quiet once supported
    ::Open3.popen2e(Shellwords.join [epubcheck_cmd, epub_file]) {|input, output, wait_thr|
      output.each {|line| puts line }
    }
  end
end
end
end