struct ParserConfig
    jl_code_block::String
    tmp_code_block::Tuple{String, String}
    variable_block::Tuple{String, String}
    function ParserConfig(config::Dict{String, String})
        return new(
            config["jl_block"],
            (config["tmp_block_start"], config["tmp_block_stop"]),
            (config["variable_block_start"], config["variable_block_stop"])
        )
    end
end

struct ParserError <: Exception
    msg::String
end

Base.showerror(io::IO, e::ParserError) = print(io, "ParserError: "*e.msg)

struct TmpStatement
    st::String
end

struct TmpCodeBlock
    contents::Array{Union{String, TmpStatement}, 1}
end

function (TCB::TmpCodeBlock)()
    code = "txt=\"\";"
    for content in TCB.contents
        if typeof(content) == TmpStatement
            code *= (content.st*";")
        else
            code *= ("txt *= \"$(apply_variables(content))\";")
        end
    end
    if length(TCB.contents) != 1
        code *= "push!(txts, txt);"
    end
    return code
end

function apply_variables(content)
    for m in eachmatch(r"{{\s*(?<variable>[\s\S]*?)\s*?}}", content)
        content = replace(content, m.match=>"\$"*m[:variable])
    end
    return content
end

## template parser
function parse_template(txt::String, config::ParserConfig)
    # length of the code blocks start/end token
    jl_block_len = length(config.jl_code_block)
    tmp_block_len = length.(config.tmp_code_block)

    # pointers into the start of the code blocks
    jl_pos, tmp_pos = zeros(Int, 2)
    # code block depth
    depth = 0
    # the number of blocks
    block_counts = ones(Int, 2)
    # index of the template
    eob_idx = 1
    idx = 1
    # end of block: this variable is used to remove the extra escape sequence from the end of the tmp code blocks
    eob = false

    # prepare the arrays to store the code blocks
    jl_codes = Array{String}(undef, 0)
    top_codes = Array{String}(undef, 0)
    tmp_codes = Array{TmpCodeBlock}(undef, 0)
    block = Array{Union{String, TmpStatement}}(undef, 0)
    out_txt = ""
    
    # main loop
    i = 1
    while i <= length(txt)
        # remove the extra escape sequence after the end of the tmp code blocks
        if eob
            if txt[min(end, i+tmp_block_len[2])] in ['\t', '\n', ' ']
                idx += 1
            else
                out_txt *= txt[eob_idx:idx]
                idx += 1
                eob = false
            end
        end
        
        #jl code block
        if txt[i:min(end, i+jl_block_len-1)] == config.jl_code_block
            if tmp_pos != 0
                throw(ParserError("invaild jl code block! code block can't be in another code block."))
            # start of jl code blocks
            elseif jl_pos == 0
                jl_pos = i
                out_txt *= txt[idx:i-1]
            # end of jl code blocks
            elseif jl_pos != 0
                code = txt[jl_pos+jl_block_len:i-1]
                top_regex = r"(using|import)\s.*[\n, ;]"
                result = eachmatch(top_regex, code)
                tops = ""
                for t in result
                    tops *= t.match
                    code = replace(code, t.match=>"")
                end
                push!(top_codes, tops)
                push!(jl_codes, code)
                out_txt*="<jlcode$(block_counts[1])>"
                block_counts[1] += 1
                idx = i + jl_block_len
                jl_pos = 0
            end
        # start of the tmp code blocks
        elseif txt[i:min(end, i+tmp_block_len[1]-1)] == config.tmp_code_block[1]
            if jl_pos != 0
                throw(ParserError("invaild code block! code block can't be in another code block."))
            end
            if depth == 0
                out_txt *= string(rstrip(txt[idx:i-1]))
            else
                push!(block, string(rstrip(txt[idx:i-1])))
            end
            tmp_pos = i
        # end of tmp code blocks
        elseif txt[i:min(end, i+tmp_block_len[2]-1)] == config.tmp_code_block[2]
            code = strip(txt[tmp_pos+tmp_block_len[1]:i-1])
            operator = split(code)[1]
            if operator == "set"
                if length(block) == 0
                    push!(tmp_codes, TmpCodeBlock([TmpStatement(code[4:end])]))
                else
                    push!(block, TmpStatement(code[4:end]))
                end
            elseif operator == "extends" && out_txt == ""
                file_name = strip(code[8:end])
                if file_name[1] == file_name[end] == '\"'
                    blocks, block_dict = parse_block(txt[i+tmp_block_len[2]:end], config)
                    open(file_name[2:end-1], "r") do f
                        txt = assign_blocks(read(f, String), blocks, block_dict, config)
                    end
                else
                    throw(ParserError("failed to read $file_name: file name have to be enclosed in double quotation marks"))
                end
                i = 1
                continue 
            elseif operator == "include"
                file_name = strip(code[8:end])
                if file_name[1] == file_name[end] == '\"'
                    open(file_name[2:end-1], "r") do f
                        txt = txt[1:tmp_pos-1] * lstrip(read(f, String)) * txt[i+tmp_block_len[2]:end]
                    end
                else
                    throw(ParserError("failed to include $file_name: file name have to be enclosed in double quotation marks"))
                end
                i = tmp_pos-1
            elseif operator == "end"
                if depth == 0
                    throw(ParserError("`end` block was found despite the depth of the code is 0."))
                end
                depth -= 1
                push!(block, TmpStatement("end"))
                if depth == 0
                    push!(tmp_codes, TmpCodeBlock(block))
                    block = Array{Union{String, TmpStatement}}(undef, 0)
                    out_txt = string(rstrip(out_txt))
                    out_txt *= "<tmpcode$(block_counts[2])>"
                    block_counts[2] += 1
                    tmp_pos = 0
                    eob_idx = i+tmp_block_len[1]
                    eob = true
                end
            else
                depth += 1
                if operator == "with"
                    push!(block, TmpStatement("let "*code[5:end]))
                else
                    push!(block, TmpStatement(code))
                end
            end
            idx = i + tmp_block_len[2]
        end
        i += 1
    end
    out_txt *= txt[idx:end]
    return out_txt, top_codes, jl_codes, tmp_codes
end

function parse_block(txt::String, config::ParserConfig)
    tmp_block_len = length.(config.tmp_code_block)
    # array containing blocks
    blocks = Array{String}(undef, 0)
    # dictionary containing pairs which represent the block name and index of the block
    block_dict = Dict{String, Int}()
    # block name
    name = ""
    # index used to point start or end of code block
    idx = 1
    tmp_pos = 1
    # whether i is in or out of block
    in_block = false

    i = 1
    while i <= length(txt)
        if txt[i:min(end, i+tmp_block_len[1]-1)] == config.tmp_code_block[1]
            tmp_pos = i
        elseif txt[i:min(end, i+tmp_block_len[2]-1)] == config.tmp_code_block[2]
            code = strip(txt[tmp_pos+tmp_block_len[1]:i-1])
            if code == "endblock"
                if !in_block
                    throw(ParserError("invalid endblock: this endblock has no start of block"))
                else
                    in_block = false
                end
                push!(blocks, strip(txt[idx:tmp_pos-1]))
                block_dict[name] = length(blocks)
            end
            tokens = split(code)
            if tokens[1] == "block"
                if in_block
                    throw(ParserError("invalid block: blocks cannot be nested"))
                else
                    in_block = true
                end
                name = tokens[2]
                idx = i+tmp_block_len[2]
            elseif tokens[1] == "include"
                file_name = tokens[2]
                if file_name[1] == file_name[end] == '\"'
                    open(file_name[2:end-1], "r") do f
                        txt = txt[1:tmp_pos-1] * lstrip(read(f, String)) * txt[i+tmp_block_len[2]:end]
                    end
                else
                    throw(ParserError("failed to include $file_name: file name have to be enclosed in double quotation marks"))
                end
                i = tmp_pos
                continue
            end
        end
        i += 1
    end
    return blocks, block_dict
end

function assign_blocks(txt::String, blocks::Array{String}, block_dict::Dict{String, Int}, config::ParserConfig)
    tmp_block_len = length.(config.tmp_code_block)
    # block name
    name = ""
    # index used to point start or end of code block
    idx = 1
    tmp_pos = 1
    # whether i is in or out of block
    in_block = false

    i = 1
    while i <= length(txt)
        if txt[i:min(end, i+tmp_block_len[1]-1)] == config.tmp_code_block[1]
            tmp_pos = i
        elseif txt[i:min(end, i+tmp_block_len[2]-1)] == config.tmp_code_block[2]
            code = strip(txt[tmp_pos+tmp_block_len[1]:i-1])
            if code == "endblock"
                if !in_block
                    throw(ParserError("invalid endblock: this endblock has no start of block"))
                else
                    in_block = false
                end
                try
                    block_content = blocks[block_dict[name]]
                    txt = txt[1:idx] * block_content * txt[i+tmp_block_len[2]:end]
                    i = idx + length(block_content) + 1
                catch
                    throw(ParserError("failed to insert block: invalid block name"))
                end
            end
            tokens = split(code)
            if tokens[1] == "block"
                if in_block
                    throw(ParserError("invalid block: blocks cannot be nested"))
                else
                    in_block = true
                end
                name = tokens[2]
                idx = tmp_pos-1
            end
        end
        i += 1
    end
    return txt
end

# configuration(TOML format) parser
function parse_config(filename::String)
    if filename[end-3:end] != "toml"
        throw(ArgumentError("Suffix of config file must be `toml`! Now, it is `$(filename[end-3:end])`."))
    end
    config = ""
    open(filename, "r") do f
        config = read(f, String)
    end
    return TOML.parse(config)
end