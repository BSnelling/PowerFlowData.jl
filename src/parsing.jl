###
### parsing
###

getbytes(source::Vector{UInt8}) = source, 1, length(source)
getbytes(source::IOBuffer) = source.data, source.ptr, source.size
getbytes(source) = getbytes(read(source))

"""
    parse_network(source) -> Network

Read a PSS/E-format `.raw` Power Flow Data file and return a [`Network`](@ref) object.
"""
function parse_network(source)
    options = Options(
        sentinel=missing,
        quoted=true,
        openquotechar='\'',
        closequotechar='\'',
        delim=',',
    )
    eol_options =  Options(
        sentinel=missing,
        openquotechar='\'',
        closequotechar='\'',
        delim='/',  # change delimiter as way to handle end-of-line comments
    )
    bytes, pos, len = getbytes(source)

    caseid, pos = parse_caseid(bytes, pos, len, options)
    @debug "caseid" pos

    # Skip the 2 lines of comments
    # TODO: confirm it is always only and exactly 2 lines of comments
    pos = next_line(bytes, pos, len)
    pos = next_line(bytes, pos, len)
    @debug "comments" pos

    nrows = count_nrow(bytes, pos, len, options)
    @debug "buses" nrows pos
    buses, pos = parse_records!(Buses(nrows), bytes, pos, len, options, eol_options)

    nrows = count_nrow(bytes, pos, len, options)
    @debug "loads" nrows pos
    loads, pos = parse_records!(Loads(nrows), bytes, pos, len, options, eol_options)

    nrows = count_nrow(bytes, pos, len, options)
    @debug "gens" nrows pos
    gens, pos = parse_records!(Generators(nrows), bytes, pos, len, options, eol_options)

    return Network(caseid, buses, loads, gens)
end

function parse_caseid(bytes, pos, len, options)
    ic, pos, code = parse_value(Int, bytes, pos, len, options)
    @debug codes(code) pos newline=newline(code)

    # Support files that have first row like:
    # 0,   100.00          / PSS/E-30.3    WED, SEP 15 2021  21:04
    # and those with first row like:
    # 0,100.0,30 / PSS(tm)E-30 RAW created      Wed, Sep 15 2021 21:04
    # TODO: avoid needing to extract `sbase` value from String?
    sbase = Parsers.tryparse(Float64, bytes, options, pos, len)
    if sbase === nothing
        str, pos, code = parse_value(String, bytes, pos, len, options)
        @debug codes(code) pos newline=newline(code)
        sbase = parse(Float64, first(split(str, '/')))
    end

    # if delimiter after `sbase` value, then won't have reached end of line.
    if !newline(code)
        pos = next_line(bytes, pos, len)
    end
    @debug codes(code) pos newline=newline(code)

    return CaseID(ic, sbase), pos
end

function parse_records!(rec::Records, bytes, pos, len, options, eol_options)
    nrows = length(getfield(rec, 1))
    nrows == 0 && return rec, pos
    for row in 1:nrows
        pos, code = parse_row!(rec, row, bytes, pos, len, options, eol_options)

        # Because we're working around end-of-line comments,
        # rows with comments won't have hit the newline character yet
        if !newline(code)
            pos = next_line(bytes, pos, len)
        end
    end

    # Data input is terminated by specifying a bus number of zero.
    # @assert peekbyte(bytes, pos) == UInt8('0')
    if !(eof(bytes, pos, len) || peekbyte(bytes, pos) == UInt8('0'))
        @warn "Not at end of $(typeof(rec)) records"
    end
    pos = next_line(bytes, pos, len)
    return rec, pos
end

function count_nrow(buf, pos, len, options)
    nlines = 0
    if eof(buf, pos, len) || peekbyte(buf, pos) == UInt8('0')
        return nlines
    end
    while true
        res = xparse(String, buf, pos, len, options)
        pos += res.tlen
        if newline(res.code)
            nlines += 1
            if eof(buf, pos, len) || peekbyte(buf, pos) == UInt8('0')
                break
            end
        end
    end
    return nlines
end

# Taken from `Parsers.checkcmtemptylines`
# TODO: move to Parsers.jl?
function next_line(bytes, pos, len)
    eof(bytes, pos, len) && return pos
    b = peekbyte(bytes, pos)
    while b !== UInt8('\n') && b !== UInt8('\r')
        pos += 1
        Parsers.incr!(bytes)  # TODO: not needed if not in Parsers.jl as got Vec{UInt8}?
        eof(bytes, pos, len) && break
        b = peekbyte(bytes, pos)
    end
    # Move forward to be past the `\r` or `\n` byte.
    pos += 1
    Parsers.incr!(bytes)
    # if line ends `\r\n`, then we're at `\n`and need to move forward again.
    if b === UInt8('\r') && !eof(bytes, pos, len) && peekbyte(bytes, pos) === UInt8('\n')
        pos += 1
        Parsers.incr!(bytes)
    end
    return pos
end

function parse_row!(rec::Records, row::Int, bytes, pos, len, options, eol_options)
    ncols = nfields(rec)
    local code::Parsers.ReturnCode
    for col in 1:ncols
        eltyp = eltype(fieldtype(typeof(rec), col))
        opts = col == ncols ? eol_options : options
        val, pos, code = parse_value(eltyp, bytes, pos, len, opts)
        @inbounds getfield(rec, col)[row] = val

        @debug codes(code) row col pos newline=newline(code)
    end
    return pos, code
end

function parse_value(T, bytes, pos, len, options)
    res = xparse(T, bytes, pos, len, options)

    invalid(res.code) && @warn codes(res.code) pos

    pos += res.tlen
    code = res.code

    val = if T === String
        Parsers.getstring(bytes, res.val, options.e)
    else
        res.val
    end
    return val, pos, code
end
