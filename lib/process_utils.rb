# This file is part of vlog-toolset.
#
# vlog-toolset is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# vlog-toolset is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with vlog-toolset. If not, see <http://www.gnu.org/licenses/>.

require 'shellwords'

class Array
  def shelljoin_wrapped
    shelljoin.gsub('\=', '=').gsub('\\ ', ' ') # https://github.com/ruby/shellwords/issues/1
  end

  # TODO: move
  def argmax
    index(max)
  end

  # TODO: move
  def unique_items?
    uniq.length == length
  end
end

def process_running?(pid)
  Process.waitpid(pid, Process::WNOHANG).nil?
rescue Errno::ECHILD
  false
end

def kill_process(pid)
  Process.kill 'SIGTERM', pid
rescue Errno::ESRCH
end
