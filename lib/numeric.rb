class Numeric
  def with_leading_zeros
    format('%016d', self)
  end
end
