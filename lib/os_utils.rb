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

require 'colorize'

MIN_SIZE = 4

def parse_free_storage(df, min = MIN_SIZE)
  kib = df.split("\n").map { |line| line.split.first(6) }.transpose.to_h['Available'].to_i
  gib = kib / (1024**2)
  text = "#{gib}G"
  gib <= [MIN_SIZE, min].max ? text.red : text
end
