require 'fileutils'

##
# A set of rdoc data for a single project (gem, path, etc.).
#
# The store manages reading and writing ri data for a project and maintains a
# cache of methods, classes and ancestors in the store.
#
# The store maintains a #cache of its contents for faster lookup.  After
# adding items to the store it must be flushed using #save_cache.  The cache
# contains the following structures:
#
#    @cache = {
#      :ancestors        => {}, # class name => ancestor names
#      :attributes       => {}, # class name => attributes
#      :class_methods    => {}, # class name => class methods
#      :instance_methods => {}, # class name => instance methods
#      :modules          => [], # classes and modules in this store
#      :pages            => [], # page names
#    }
#--
# TODO need to prune classes

class RDoc::Store

  ##
  # Errors raised from loading or saving the store

  class Error < RDoc::Error
  end

  ##
  # Raised when a stored file for a class, module, page or method is missing.

  class MissingFileError < Error

    ##
    # The store the file should exist in

    attr_reader :store

    ##
    # The file the #name should be saved as

    attr_reader :file

    ##
    # The name of the object the #file would be loaded from

    attr_reader :name

    ##
    # Creates a new MissingFileError for the missing +file+ for the given
    # +name+ that should have been in the +store+.

    def initialize store, file, name
      @store = store
      @file  = file
      @name  = name
    end

    def message
      "store at #{@store.path} missing file #{@file} for #{@name}"
    end

  end

  ##
  # Stores the name of the C variable a class belongs to.  This helps wire up
  # classes defined from C across files.

  attr_reader :c_enclosure_classes

  ##
  # If true this Store will not write any files

  attr_accessor :dry_run

  ##
  # Path this store reads or writes

  attr_accessor :path

  ##
  # The RDoc::RDoc driver for this parse tree.  This allows classes consulting
  # the documentation tree to access user-set options, for example.

  attr_accessor :rdoc

  ##
  # Type of ri datastore this was loaded from.  See RDoc::RI::Driver,
  # RDoc::RI::Paths.

  attr_accessor :type

  ##
  # The contents of the Store

  attr_reader :cache

  ##
  # The encoding of the contents in the Store

  attr_accessor :encoding

  ##
  # Creates a new Store of +type+ that will load or save to +path+

  def initialize path = nil, type = nil
    @dry_run  = false
    @type     = type
    @path     = path
    @rdoc     = nil
    @encoding = nil

    @cache = {
      :ancestors        => {},
      :attributes       => {},
      :class_methods    => {},
      :encoding         => @encoding,
      :instance_methods => {},
      :modules          => [],
      :pages            => [],
    }

    @classes_hash = {}
    @modules_hash = {}
    @files_hash   = {}

    @c_enclosure_classes = {}

    @unique_classes = nil
    @unique_modules = nil
  end

  ##
  # Adds the file with +name+ as an RDoc::TopLevel to the store.  Returns the
  # created RDoc::TopLevel.

  def add_file name
    unless top_level = @files_hash[name] then
      top_level = RDoc::TopLevel.new name
      top_level.store = self
      @files_hash[name] = top_level
    end

    top_level
  end

  ##
  # Returns all classes discovered by RDoc

  def all_classes
    @classes_hash.values
  end

  ##
  # Returns all classes and modules discovered by RDoc

  def all_classes_and_modules
    @classes_hash.values + @modules_hash.values
  end

  ##
  # All TopLevels known to RDoc

  def all_files
    @files_hash.values
  end

  ##
  # Returns all modules discovered by RDoc

  def all_modules
    modules_hash.values
  end

  ##
  # Ancestors cache accessor.  Maps a klass name to an Array of its ancestors
  # in this store.  If Foo in this store inherits from Object, Kernel won't be
  # listed (it will be included from ruby's ri store).

  def ancestors
    @cache[:ancestors]
  end

  ##
  # Attributes cache accessor.  Maps a class to an Array of its attributes.

  def attributes
    @cache[:attributes]
  end

  ##
  # Path to the cache file

  def cache_path
    File.join @path, 'cache.ri'
  end

  ##
  # Path to the ri data for +klass_name+

  def class_file klass_name
    name = klass_name.split('::').last
    File.join class_path(klass_name), "cdesc-#{name}.ri"
  end

  ##
  # Class methods cache accessor.  Maps a class to an Array of its class
  # methods (not full name).

  def class_methods
    @cache[:class_methods]
  end

  ##
  # Path where data for +klass_name+ will be stored (methods or class data)

  def class_path klass_name
    File.join @path, *klass_name.split('::')
  end

  ##
  # Hash of all classes known to RDoc

  def classes_hash
    @classes_hash
  end

  ##
  # Removes empty items and ensures item in each collection are unique and
  # sorted

  def clean_cache_collection collection # :nodoc:
    collection.each do |name, item|
      if item.empty? then
        collection.delete name
      else
        # HACK mongrel-1.1.5 documents its files twice
        item.uniq!
        item.sort!
      end
    end
  end

  ##
  # Prepares the RDoc code object tree for use by a generator.
  #
  # It finds unique classes/modules defined, and replaces classes/modules that
  # are aliases for another one by a copy with RDoc::ClassModule#is_alias_for
  # set.
  #
  # It updates the RDoc::ClassModule#constant_aliases attribute of "real"
  # classes or modules.
  #
  # It also completely removes the classes and modules that should be removed
  # from the documentation and the methods that have a visibility below
  # +min_visibility+, which is the <tt>--visibility</tt> option.
  #
  # See also RDoc::Context#remove_from_documentation?

  def complete min_visibility
    fix_basic_object_inheritance

    # cache included modules before they are removed from the documentation
    all_classes_and_modules.each { |cm| cm.ancestors }

    remove_nodoc @classes_hash
    remove_nodoc @modules_hash

    @unique_classes = find_unique @classes_hash
    @unique_modules = find_unique @modules_hash

    unique_classes_and_modules.each do |cm|
      cm.complete min_visibility
    end

    @files_hash.each_key do |file_name|
      tl = @files_hash[file_name]

      unless tl.text? then
        tl.modules_hash.clear
        tl.classes_hash.clear

        tl.classes_or_modules.each do |cm|
          name = cm.full_name
          if cm.type == 'class' then
            tl.classes_hash[name] = cm if @classes_hash[name]
          else
            tl.modules_hash[name] = cm if @modules_hash[name]
          end
        end
      end
    end
  end

  ##
  # Hash of all files known to RDoc

  def files_hash
    @files_hash
  end

  ##
  # Finds the class with +name+ in all discovered classes

  def find_class_named name
    @classes_hash[name]
  end

  ##
  # Finds the class with +name+ starting in namespace +from+

  def find_class_named_from name, from
    from = find_class_named from unless RDoc::Context === from

    until RDoc::TopLevel === from do
      return nil unless from

      klass = from.find_class_named name
      return klass if klass

      from = from.parent
    end

    find_class_named name
  end

  ##
  # Finds the class or module with +name+

  def find_class_or_module name
    name = $' if name =~ /^::/
    @classes_hash[name] || @modules_hash[name]
  end

  ##
  # Finds the file with +name+ in all discovered files

  def find_file_named name
    @files_hash[name]
  end

  ##
  # Finds the module with +name+ in all discovered modules

  def find_module_named name
    @modules_hash[name]
  end

  ##
  # Finds unique classes/modules defined in +all_hash+,
  # and returns them as an array. Performs the alias
  # updates in +all_hash+: see ::complete.
  #--
  # TODO  aliases should be registered by Context#add_module_alias

  def find_unique all_hash
    unique = []

    all_hash.each_pair do |full_name, cm|
      unique << cm if full_name == cm.full_name
    end

    unique
  end

  ##
  # Fixes the erroneous <tt>BasicObject < Object</tt> in 1.9.
  #
  # Because we assumed all classes without a stated superclass
  # inherit from Object, we have the above wrong inheritance.
  #
  # We fix BasicObject right away if we are running in a Ruby
  # version >= 1.9. If not, we may be documenting 1.9 source
  # while running under 1.8: we search the files of BasicObject
  # for "object.c", and fix the inheritance if we find it.

  def fix_basic_object_inheritance
    basic = classes_hash['BasicObject']
    return unless basic
    if RUBY_VERSION >= '1.9'
      basic.superclass = nil
    elsif basic.in_files.any? { |f| File.basename(f.full_name) == 'object.c' }
      basic.superclass = nil
    end
  end

  ##
  # Friendly rendition of #path

  def friendly_path
    case type
    when :gem    then
      sep = Regexp.union(*['/', File::ALT_SEPARATOR].compact)
      @path =~ /#{sep}doc#{sep}(.*?)#{sep}ri$/
      "gem #{$1}"
    when :home   then '~/.ri'
    when :site   then 'ruby site'
    when :system then 'ruby core'
    else @path
    end
  end

  def inspect # :nodoc:
    "#<%s:0x%x %s %p>" % [self.class, object_id, @path, module_names.sort]
  end

  ##
  # Instance methods cache accessor.  Maps a class to an Array of its
  # instance methods (not full name).

  def instance_methods
    @cache[:instance_methods]
  end

  ##
  # Loads all items from this store into memory.  This recreates a
  # documentation tree for use by a generator

  def load_all
    load_cache

    module_names.each do |module_name|
      mod = load_class module_name

      # load method documentation since the loaded class/module does not have
      # it
      loaded_methods = mod.method_list.map do |method|
        load_method module_name, method.full_name
      end

      mod.method_list.replace loaded_methods

      loaded_attributes = mod.attributes.map do |attribute|
        load_method module_name, attribute.full_name
      end

      mod.attributes.replace loaded_attributes

      case mod
      when RDoc::NormalClass then
        @classes_hash[module_name] = mod
      when RDoc::NormalModule then
        @modules_hash[module_name] = mod
      end
    end

    # This is really slow
    module_names.each do |module_name|
      mod = find_class_or_module module_name

      mod.parent = find_class_or_module mod.parent_name

      module_names.select do |name|
        name =~ /^#{module_name}::[^:]+$/
      end.each do |descendent_name|
        descendent = find_class_or_module descendent_name

        case descendent
        when RDoc::NormalClass then
          mod.classes_hash[descendent_name] = descendent
        when RDoc::NormalModule then
          mod.modules_hash[descendent_name] = descendent
        end
      end
    end

    @cache[:pages].each do |page_name|
      page = load_page page_name
      @files_hash[page_name] = page
    end
  end

  ##
  # Loads cache file for this store

  def load_cache
    #orig_enc = @encoding

    open cache_path, 'rb' do |io|
      @cache = Marshal.load io.read
    end

    load_enc = @cache[:encoding]

    # TODO this feature will be time-consuming to add:
    # a) Encodings may be incompatible but transcodeable
    # b) Need to warn in the appropriate spots, wherever they may be
    # c) Need to handle cross-cache differences in encodings
    # d) Need to warn when generating into a cache with different encodings
    #
    #if orig_enc and load_enc != orig_enc then
    #  warn "Cached encoding #{load_enc} is incompatible with #{orig_enc}\n" \
    #       "from #{path}/cache.ri" unless
    #    Encoding.compatible? orig_enc, load_enc
    #end

    @encoding = load_enc unless @encoding

    @cache[:pages] ||= []

    @cache
  rescue Errno::ENOENT
  end

  ##
  # Loads ri data for +klass_name+

  def load_class klass_name
    file = class_file klass_name

    open file, 'rb' do |io|
      obj = Marshal.load io.read
      obj.store = self
      obj
    end
  rescue Errno::ENOENT => e
    error = MissingFileError.new(self, file, klass_name)
    error.set_backtrace e.backtrace
    raise error
  end

  ##
  # Loads ri data for +method_name+ in +klass_name+

  def load_method klass_name, method_name
    file = method_file klass_name, method_name

    open file, 'rb' do |io|
      obj = Marshal.load io.read
      obj.store = self
      obj
    end
  rescue Errno::ENOENT => e
    error = MissingFileError.new(self, file, klass_name + method_name)
    error.set_backtrace e.backtrace
    raise error
  end

  ##
  # Loads ri data for +page_name+

  def load_page page_name
    file = page_file page_name

    open file, 'rb' do |io|
      obj = Marshal.load io.read
      obj.store = self
      obj
    end
  rescue Errno::ENOENT => e
    error = MissingFileError.new(self, file, page_name)
    error.set_backtrace e.backtrace
    raise error
  end

  ##
  # Path to the ri data for +method_name+ in +klass_name+

  def method_file klass_name, method_name
    method_name = method_name.split('::').last
    method_name =~ /#(.*)/
    method_type = $1 ? 'i' : 'c'
    method_name = $1 if $1

    method_name = if ''.respond_to? :ord then
                    method_name.gsub(/\W/) { "%%%02x" % $&[0].ord }
                  else
                    method_name.gsub(/\W/) { "%%%02x" % $&[0] }
                  end

    File.join class_path(klass_name), "#{method_name}-#{method_type}.ri"
  end

  ##
  # Modules cache accessor.  An Array of all the module (and class) names in
  # the store.

  def module_names
    @cache[:modules]
  end

  ##
  # Hash of all modules known to RDoc

  def modules_hash
    @modules_hash
  end

  ##
  # Returns the RDoc::TopLevel that is a text file and has the given +name+

  def page name
    @files_hash.each_value.find do |file|
      file.text? and file.page_name == name
    end
  end

  ##
  # Path to the ri data for +page_name+

  def page_file page_name
    file_name = File.basename(page_name).gsub('.', '_')

    File.join @path, File.dirname(page_name), "page-#{file_name}.ri"
  end

  ##
  # Removes from +all_hash+ the contexts that are nodoc or have no content.
  #
  # See RDoc::Context#remove_from_documentation?

  def remove_nodoc all_hash
    all_hash.keys.each do |name|
      context = all_hash[name]
      all_hash.delete(name) if context.remove_from_documentation?
    end
  end

  ##
  # Saves all entries in the store

  def save
    load_cache

    all_classes_and_modules.each do |klass|
      save_class klass

      klass.each_method do |method|
        save_method klass, method
      end

      klass.each_attribute do |attribute|
        save_method klass, attribute
      end
    end

    all_files.each do |file|
      save_page file
    end

    save_cache
  end

  ##
  # Writes the cache file for this store

  def save_cache
    clean_cache_collection @cache[:ancestors]
    clean_cache_collection @cache[:attributes]
    clean_cache_collection @cache[:class_methods]
    clean_cache_collection @cache[:instance_methods]

    @cache[:modules].uniq!
    @cache[:modules].sort!

    @cache[:pages].uniq!
    @cache[:pages].sort!

    @cache[:encoding] = @encoding # this gets set twice due to assert_cache

    return if @dry_run

    marshal = Marshal.dump @cache

    open cache_path, 'wb' do |io|
      io.write marshal
    end
  end

  ##
  # Writes the ri data for +klass+ (or module)

  def save_class klass
    full_name = klass.full_name

    FileUtils.mkdir_p class_path(full_name) unless @dry_run

    @cache[:modules] << full_name

    path = class_file full_name

    begin
      disk_klass = load_class full_name

      klass = disk_klass.merge klass
    rescue MissingFileError
    end

    # BasicObject has no ancestors
    ancestors = klass.direct_ancestors.compact.map do |ancestor|
      # HACK for classes we don't know about (class X < RuntimeError)
      String === ancestor ? ancestor : ancestor.full_name
    end

    @cache[:ancestors][full_name] ||= []
    @cache[:ancestors][full_name].concat ancestors

    attributes = klass.attributes.map do |attribute|
      "#{attribute.definition} #{attribute.name}"
    end

    unless attributes.empty? then
      @cache[:attributes][full_name] ||= []
      @cache[:attributes][full_name].concat attributes
    end

    to_delete = []

    unless klass.method_list.empty? then
      @cache[:class_methods][full_name]    ||= []
      @cache[:instance_methods][full_name] ||= []

      class_methods, instance_methods =
        klass.method_list.partition { |meth| meth.singleton }

      class_methods    = class_methods.   map { |method| method.name }
      instance_methods = instance_methods.map { |method| method.name }

      old = @cache[:class_methods][full_name] - class_methods
      to_delete.concat old.map { |method|
        method_file full_name, "#{full_name}::#{method}"
      }

      old = @cache[:instance_methods][full_name] - instance_methods
      to_delete.concat old.map { |method|
        method_file full_name, "#{full_name}##{method}"
      }

      @cache[:class_methods][full_name]    = class_methods
      @cache[:instance_methods][full_name] = instance_methods
    end

    return if @dry_run

    FileUtils.rm_f to_delete

    marshal = Marshal.dump klass

    open path, 'wb' do |io|
      io.write marshal
    end
  end

  ##
  # Writes the ri data for +method+ on +klass+

  def save_method klass, method
    full_name = klass.full_name

    FileUtils.mkdir_p class_path(full_name) unless @dry_run

    cache = if method.singleton then
              @cache[:class_methods]
            else
              @cache[:instance_methods]
            end
    cache[full_name] ||= []
    cache[full_name] << method.name

    return if @dry_run

    marshal = Marshal.dump method

    open method_file(full_name, method.full_name), 'wb' do |io|
      io.write marshal
    end
  end

  ##
  # Writes the ri data for +page+

  def save_page page
    return unless page.text?

    path = page_file page.full_name

    FileUtils.mkdir_p File.dirname(path) unless @dry_run

    cache[:pages] ||= []
    cache[:pages] << page.full_name

    return if @dry_run

    marshal = Marshal.dump page

    open path, 'wb' do |io|
      io.write marshal
    end
  end

  ##
  # Returns the unique classes discovered by RDoc.
  #
  # ::complete must have been called prior to using this method.

  def unique_classes
    @unique_classes
  end

  ##
  # Returns the unique classes and modules discovered by RDoc.
  # ::complete must have been called prior to using this method.

  def unique_classes_and_modules
    @unique_classes + @unique_modules
  end

  ##
  # Returns the unique modules discovered by RDoc.
  # ::complete must have been called prior to using this method.

  def unique_modules
    @unique_modules
  end

end

