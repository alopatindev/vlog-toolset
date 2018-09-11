class Numeric
  def with_leading_zeros
    format('0%05d', self)
  end
end
