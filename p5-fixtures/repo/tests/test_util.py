from src.util import double


def test_double():
    assert double(2) == 4


def test_double_zero():
    assert double(0) == 0
