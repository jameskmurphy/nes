import setuptools
from Cython.Build import cythonize

with open("README.md", "r") as fh:
    long_description = fh.read()

setuptools.setup(
    name="pyntendo",
    version="0.0.1",
    author="James Murphy",
    author_email="jkmurphy314@gmail.com",
    description="A Nintendo Entertainment System (NES) emulator in Python and Cython",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/jameskmurphy/nes",
    packages=setuptools.find_packages(),
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
    ],
    python_requires='>=3.6',
    ext_modules = cythonize("nes/cycore/*.pyx")
)