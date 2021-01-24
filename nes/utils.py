
def load_rom_raw(filename):
    """
    Loads the data from a .nes file as the nesheader and the rom data without further processing
    :param filename:
    :return:
    """
    with open(filename, "rb") as f:
        nesheader = f.read(16)
        bytecode = f.read()
    return bytecode, nesheader

def load_palette(filename):
    """
    Loads a 64 value palette from a .pal file (binary, 3 bytes per color).
    Palettes can be created from bisqwit's tool here: https://bisqwit.iki.fi/utils/nespalette.php
    :return: A list of rgb tuples (elements in range 0-255) corresponding to the palette colors
    """
    with open(filename, "rb") as f:
        pal = f.read()
    palette = []
    for i in range(64):
        palette.append( (pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]) )
    return palette
