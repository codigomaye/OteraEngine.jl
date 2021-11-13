module OteraEngine

export Template

"""
    Template(html::String; path::Bool=true)
This is the only structure and function of this package.
This structure has 2 parameter,
- `html` is the path to the HTML file or HTML of String type.
- `path` determines whether the parameter `html` represents the file path. The default value is `true`.

# HTML
You can write the code of Template in JuliaLang, and just write the variables you want to output to a HTML at the end of the code.
The code needs to be enclosed by ```.

For exmaple, this HTML work:
```
<html>
    <head><title>OteraEngine Test</title></head>
    <body>
        Hello, `usr`!
    </body>
</html>
```

# Rendering
After you create a Template, you just have to execute the codes! For this, you use the Function-like Object of Template structure.
    tmp(; init::Expr)
variables are initialized by `init`(`init` is the parameter for Function-like Object). `init` must be `Expr`type. If you don't pass the `init`, the initialization won't be done.
Please see the example below.

# Example
```@repl
tmp = Template("./test1.html") #The last HTML code
init = Dict("usr"=>"OteraEngine")
result = tmp(init)
println(result)
```
"""
struct Template
    splitted_html::Array{String, 1}
    codes::Array{String, 1}
end

function Template(html::String; path::Bool=true)
    if path
        open(html, "r") do f
            html = read(f, String)
        end
    end
    code = ""
    codes = Array{String}(undef, 0)
    splitted_html = Array{String}(undef, 0)
    is_code=false
    i=1
    j=0
    for s in html
        if s=='`'
            if is_code
                is_code=false
                i = j+2
                push!(codes, replace(code, "\n"=>"; "))
                code=""
            else
                push!(splitted_html, html[i:j])
                is_code=true
            end
        elseif is_code
            code*=s
        end
        j+=1
    end
    push!(splitted_html, html[i:j])
    return Template(splitted_html, codes)
end

function (tmp::Template)(init::Dict{String, T}) where T <: Any
    html = tmp.splitted_html[1]
    for (part_of_html, code) in zip(tmp.splitted_html[2:end], tmp.codes)
        arg_string = ""
        for v in keys(init)
            arg_string*=(v*",")
        end
        eval(Meta.parse("function f("*arg_string*"); "*code*";end"))
        html*=string(Base.invokelatest(f, values(init)...))*part_of_html
    end
    return html
end

function (tmp::Template)()
    html = tmp.splitted_html[1]
    for (part_of_html, code) in zip(tmp.splitted_html[2:end], tmp.codes)
        eval(Meta.parse("function f();"*code*";end"))
        html*=string(Base.invokelatest(f))*part_of_html
    end
    return html
end

end