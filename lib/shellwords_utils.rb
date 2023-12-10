require 'shellwords'

# TODO: move to process_utils?

class Array
  def shelljoin_wrapped
    shelljoin.gsub('\=', '=').gsub('\\ ', ' ') # https://github.com/ruby/shellwords/issues/1
  end
end
