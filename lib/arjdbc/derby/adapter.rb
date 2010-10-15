require 'arjdbc/jdbc/missing_functionality_helper'

module ::ArJdbc
  module Derby
    def self.column_selector
      [/derby/i, lambda {|cfg,col| col.extend(::ArJdbc::Derby::Column)}]
    end

    def self.monkey_rails
      unless @already_monkeyd
        # Needed because Rails is broken wrt to quoting of
        # some values. Most databases are nice about it,
        # but not Derby. The real issue is that you can't
        # compare a CHAR value to a NUMBER column.
        ::ActiveRecord::Associations::ClassMethods.module_eval do
          private

          def select_limited_ids_list(options, join_dependency)
            connection.select_all(
                                  construct_finder_sql_for_association_limiting(options, join_dependency),
                                  "#{name} Load IDs For Limited Eager Loading"
                                  ).collect { |row| connection.quote(row[primary_key], columns_hash[primary_key]) }.join(", ")
          end
        end

        @already_monkeyd = true
      end
    end

    def self.extended(*args)
      monkey_rails
    end

    def self.included(*args)
      monkey_rails
    end

    module Column
      def simplified_type(field_type)
        return :boolean if field_type =~ /smallint/i
        return :float if field_type =~ /real/i
        super
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        # jdbc returns column default strings with actual single quotes around the value.
        return $1 if value =~ /^'(.*)'$/

        value
      end
    end

    def adapter_name #:nodoc:
      'Derby'
    end

    include ArJdbc::MissingFunctionalityHelper

    def index_name_length
      128
    end

    # Convert the speficied column type to a SQL string.  In Derby, :integers cannot specify
    # a limit.
    def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
      return super unless type == :integer

      native = native_database_types[type.to_s.downcase.to_sym]
      native.is_a?(Hash) ? native[:name] : native
    end

    def modify_types(tp)
      tp[:primary_key] = "int generated by default as identity NOT NULL PRIMARY KEY"
      tp[:integer][:limit] = nil
      tp[:string][:limit] = 256
      tp[:boolean] = {:name => "smallint"}
      tp
    end

    # Override default -- fix case where ActiveRecord passes :default => nil, :null => true
    def add_column_options!(sql, options)
      options.delete(:default) if options.has_key?(:default) && options[:default].nil?
      options.delete(:null) if options.has_key?(:null) && (options[:null].nil? || options[:null] == true)
      sql << " DEFAULT #{quote(options.delete(:default))}" if options.has_key?(:default)
      super
    end

    def classes_for_table_name(table)
      ActiveRecord::Base.send(:subclasses).select {|klass| klass.table_name == table}
    end

    # Set the sequence to the max value of the table's column.
    def reset_sequence!(table, column, sequence = nil)
      mpk = select_value("SELECT MAX(#{quote_column_name(column)}) FROM #{quote_table_name(table)}")
      execute("ALTER TABLE #{quote_table_name(table)} ALTER COLUMN #{quote_column_name(column)} RESTART WITH #{mpk.to_i + 1}")
    end

    def reset_pk_sequence!(table, pk = nil, sequence = nil)
      klasses = classes_for_table_name(table)
      klass   = klasses.nil? ? nil : klasses.first
      pk      = klass.primary_key unless klass.nil?
      if pk && klass.columns_hash[pk].type == :integer
        reset_sequence!(klass.table_name, pk)
      end
    end

    def remove_index(table_name, options) #:nodoc:
      execute "DROP INDEX #{index_name(table_name, options)}"
    end

    def rename_table(name, new_name)
      execute "RENAME TABLE #{quote_table_name(name)} TO #{quote_table_name(new_name)}"
    end

    AUTO_INC_STMT2 = "SELECT AUTOINCREMENTSTART, AUTOINCREMENTINC, COLUMNNAME, REFERENCEID, COLUMNDEFAULT FROM SYS.SYSCOLUMNS WHERE REFERENCEID = (SELECT T.TABLEID FROM SYS.SYSTABLES T WHERE T.TABLENAME = '%s') AND COLUMNNAME = '%s'"

    def add_quotes(name)
      return name unless name
      %Q{"#{name}"}
    end

    def strip_quotes(str)
      return str unless str
      return str unless /^(["']).*\1$/ =~ str
      str[1..-2]
    end

    def expand_double_quotes(name)
      return name unless name && name['"']
      name.gsub(/"/,'""')
    end

    def auto_increment_stmt(tname, cname)
      stmt = AUTO_INC_STMT2 % [tname, strip_quotes(cname)]
      data = execute(stmt).first
      if data
        start = data['autoincrementstart']
        if start
          coldef = ""
          coldef << " GENERATED " << (data['columndefault'].nil? ? "ALWAYS" : "BY DEFAULT ")
          coldef << "AS IDENTITY (START WITH "
          coldef << start
          coldef << ", INCREMENT BY "
          coldef << data['autoincrementinc']
          coldef << ")"
          return coldef
        end
      end
      ""
    end


    def add_column(table_name, column_name, type, options = {})
      if option_not_null = (options[:null] == false)
        options.delete(:null)
      end
      add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ADD #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      add_column_options!(add_column_sql, options)
      execute(add_column_sql)
      if option_not_null
        alter_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} NOT NULL"
        execute(alter_column_sql)
      end
    end

    def execute(sql, name = nil)
      if sql =~ /\A\s*(UPDATE|INSERT)/i
        i = sql =~ /\swhere\s/im
        if i
          sql[i..-1] = sql[i..-1].gsub(/!=\s*NULL/, 'IS NOT NULL').gsub(/=\sNULL/i, 'IS NULL')
        end
      else
        sql.gsub!(/= NULL/i, 'IS NULL')
      end
      super
    end

    # SELECT DISTINCT clause for a given set of columns and a given ORDER BY clause.
    #
    # Derby requires the ORDER BY columns in the select list for distinct queries, and
    # requires that the ORDER BY include the distinct column.
    #
    #   distinct("posts.id", "posts.created_at desc")
    #
    # Based on distinct method for PostgreSQL Adapter
    def distinct(columns, order_by)
      return "DISTINCT #{columns}" if order_by.blank?

      # construct a clean list of column names from the ORDER BY clause, removing
      # any asc/desc modifiers
      order_columns = order_by.split(',').collect { |s| s.split.first }
      order_columns.delete_if(&:blank?)
      order_columns = order_columns.zip((0...order_columns.size).to_a).map { |s,i| "#{s} AS alias_#{i}" }

      # return a DISTINCT clause that's distinct on the columns we want but includes
      # all the required columns for the ORDER BY to work properly
      sql = "DISTINCT #{columns}, #{order_columns * ', '}"
      sql
    end

    SIZEABLE = %w(VARCHAR CLOB BLOB)

    def structure_dump #:nodoc:
      definition=""
      rs = @connection.connection.meta_data.getTables(nil,nil,nil,["TABLE"].to_java(:string))
      while rs.next
        tname = rs.getString(3)
        definition << "CREATE TABLE #{tname} (\n"
        rs2 = @connection.connection.meta_data.getColumns(nil,nil,tname,nil)
        first_col = true
        while rs2.next
          col_name = add_quotes(rs2.getString(4));
          default = ""
          d1 = rs2.getString(13)
          if d1 =~ /^GENERATED_/
            default = auto_increment_stmt(tname, col_name)
          elsif d1
            default = " DEFAULT #{d1}"
          end

          type = rs2.getString(6)
          col_size = rs2.getString(7)
          nulling = (rs2.getString(18) == 'NO' ? " NOT NULL" : "")
          create_col_string = add_quotes(expand_double_quotes(strip_quotes(col_name))) +
            " " +
            type +
            (SIZEABLE.include?(type) ? "(#{col_size})" : "") +
            nulling +
            default
          if !first_col
            create_col_string = ",\n #{create_col_string}"
          else
            create_col_string = " #{create_col_string}"
          end

          definition << create_col_string

          first_col = false
        end
        definition << ");\n\n"
      end
      definition
    end

    def remove_column(table_name, column_name)
      execute "ALTER TABLE #{quote_table_name(table_name)} DROP COLUMN #{quote_column_name(column_name)} RESTRICT"
    end

    # Notes about changing in Derby:
    #    http://db.apache.org/derby/docs/10.2/ref/rrefsqlj81859.html#rrefsqlj81859__rrefsqlj37860)
    #
    # We support changing columns using the strategy outlined in:
    #    https://issues.apache.org/jira/browse/DERBY-1515
    #
    # This feature has not made it into a formal release and is not in Java 6.  We will
    # need to conditionally support this somehow (supposed to arrive for 10.3.0.0)
    def change_column(table_name, column_name, type, options = {})
      # null/not nulling is easy, handle that separately
      if options.include?(:null)
        # This seems to only work with 10.2 of Derby
        if options.delete(:null) == false
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} NOT NULL"
        else
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} NULL"
        end
      end

      # anything left to do?
      unless options.empty?
        begin
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} SET DATA TYPE #{type_to_sql(type, options[:limit])}"
        rescue
          transaction do
            temp_new_column_name = "#{column_name}_newtype"
            # 1) ALTER TABLE t ADD COLUMN c1_newtype NEWTYPE;
            add_column table_name, temp_new_column_name, type, options
            # 2) UPDATE t SET c1_newtype = c1;
            execute "UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(temp_new_column_name)} = CAST(#{quote_column_name(column_name)} AS #{type_to_sql(type, options[:limit])})"
            # 3) ALTER TABLE t DROP COLUMN c1;
            remove_column table_name, column_name
            # 4) ALTER TABLE t RENAME COLUMN c1_newtype to c1;
            rename_column table_name, temp_new_column_name, column_name
          end
        end
      end
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "RENAME COLUMN #{quote_table_name(table_name)}.#{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
    end

    def primary_keys(table_name)
      @connection.primary_keys table_name.to_s.upcase
    end

    def columns(table_name, name=nil)
      @connection.columns_internal(table_name.to_s, name, derby_schema)
    end

    def tables
      @connection.tables(nil, derby_schema)
    end

    def recreate_database(db_name)
      tables.each do |t|
        drop_table t
      end
    end

    # For DDL it appears you can quote "" column names, but in queries (like insert it errors out?)
    def quote_column_name(name) #:nodoc:
      name = name.to_s
      if /^(references|integer|key|group|year)$/i =~ name
        %Q{"#{name.upcase}"}
      elsif /[A-Z]/ =~ name && /[a-z]/ =~ name
        %Q{"#{name}"}
      elsif name =~ /[\s-]/
        %Q{"#{name.upcase}"}
      elsif name =~ /^[_\d]/
        %Q{"#{name.upcase}"}
      else
        name
      end
    end

    def quoted_true
      '1'
    end

    def quoted_false
      '0'
    end

    def add_limit_offset!(sql, options) #:nodoc:
      if options[:offset]
        sql << " OFFSET #{options[:offset]} ROWS"
      end
      if options[:limit]
        #ROWS/ROW and FIRST/NEXT mean the same
        sql << " FETCH FIRST #{options[:limit]} ROWS ONLY"
      end
    end

    private
    # Derby appears to define schemas using the username
    def derby_schema
      if @config.has_key?(:schema)
        config[:schema]
      else
        (@config[:username] && @config[:username].to_s) || ''
      end
    end
  end
end


