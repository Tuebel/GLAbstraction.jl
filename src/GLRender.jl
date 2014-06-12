export render
#using React

function render(renderObject::RenderObject)
    programID = renderObject.vertexArray.program.id
    glUseProgram(programID)
    render(renderObject.uniforms)
    println(renderObject.uniforms)
    render(renderObject.vertexArray)
end

function render(vao::GLVertexArray)
    glBindVertexArray(vao.id)
    if vao.indexLength > 0
        glDrawElements(GL_TRIANGLES, vao.indexLength, GL_UNSIGNED_INT, GL_NONE)
    else
        glDrawArrays(GL_TRIANGLES, 0, vao.length)
    end
end

function render(x::FuncWithArgs)
    apply(x.f, x.args)
end
function render(x::GLRenderObject)
    for elem in x.preRenderFunctions
        apply(elem...)
    end

    glUseProgram(x.program.id)
    glBindVertexArray(x.vertexArray.id)
    render(x.uniforms)
    render(x.textures)

    for elem in x.postRenderFunctions
        apply(elem...)
    end
end


#Render Uniforms

function render(obj::Dict{ASCIIString, Any}, programID)
  for elem in obj
    render(elem..., programID)
  end
end

function render(obj::AbstractArray)
  for elem in obj
    render(elem...)
  end
end

#handle all uniform objects

setProgramDefault(attribute::ASCIIString, anyUniform, programID::GLuint)    = setProgramDefault(glGetUniformLocation(id, attribute), anyUniform, programID)
setProgramDefault(attribute::Symbol, anyUniform, programID::GLuint)         = setProgramDefault(glGetUniformLocation(id, string(attribute)), anyUniform, programID)

render(attribute::ASCIIString, anyUniform, programID::GLuint)               = render(glGetUniformLocation(programID, attribute), anyUniform)
render(attribute::Symbol, anyUniform, programID::GLuint)                    = render(glGetUniformLocation(programID, string(attribute)), anyUniform)


function render(location::GLint, t::Texture)
    activeTarget = GL_TEXTURE0 + uint32(location)
    glActiveTexture(activeTarget)
    glBindTexture(t.textureType, t.id)
    glUniform1i(t.id, location)
end
function setProgramDefault(location::GLint, t::Texture, programID, target = 0)
    glProgramUniform1i(location, target, programID)
end

function render(location::GLint, cam::Camera)
    render(location, cam.mvp)
end
function setProgramDefault(location::GLint, cam::Camera, programID)
    setProgramDefault(location, cam.mvp, programID)
end
#=
function render(location::GLint, input::Input)
    render(location, input.value)
end
=#
function setProgramDefault(location::GLint, object::Array, programID)
    func = getUniformFunction(object, "Program")
    D = length(size(object))
    T = eltype(object)
    objectPtr = convert(Ptr{T}, pointer(object))
    if D == 1
        func(programID, location, 1, objectPtr)
    elseif D == 2
        func(programID, location, 1, GL_FALSE, objectPtr)
    else
        error("glUniform: unsupported dimensionality")
    end
end
render(location::GLint, object::Real)               = render(location, [object])
setProgramDefault(location::GLint, object::Real, programID)    = setProgramDefault(location, [object], programID)

function render(location::GLint, object::Array)
    func = getUniformFunction(object, "")
    D = length(size(object))
    T = eltype(object)
    objectPtr = convert(Ptr{T}, pointer(object))
    if D == 1
        func(location, 1, objectPtr)
    elseif D == 2
        func(location, 1, GL_FALSE, object)
    else
        error("glUniform: unsupported dimensionality")
    end
end

function getUniformFunction(object::Array, program::ASCIIString)
    T = eltype(object)
    D = length(size(object))
    @assert(!isempty(object))
    @assert D <= 2
    matrix = D == 2
    if matrix
        @assert T <: FloatingPoint #There are only functions for Float32 matrixes
    end

    dims = size(object)

    if D == 1 || dims[1] == dims[2]
        cardinality = string(dims[1])
    else
        cardinality = string(dims[1], "x", dims[2])
    end
    if T == GLuint
        elementType = "uiv"
    elseif T == GLint
        elementType = "iv"
    elseif T == GLfloat
        elementType = "fv"
    else
        error("type not supported: ", T)
    end
    func = eval(parse("gl" *program* "Uniform" * (matrix ? "Matrix" : "")* cardinality *elementType))
end



##############################################################################################
#  Generic render functions 
#####
function enableTransparency()
    glEnable(GL_BLEND)
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
end

function drawVertexArray(x::GLRenderObject)   
    glDrawArrays(x.vertexArray.primitiveMode, 0, x.vertexArray.size)
end

export enableTransparency, drawVertexArray, render