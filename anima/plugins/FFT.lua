local 	PING_TEXTURE_UNIT = 0
local    PONG_TEXTURE_UNIT = 1
local    FILTER_TEXTURE_UNIT = 2
local    ORIGINAL_SPECTRUM_TEXTURE_UNIT = 3
local    FILTERED_SPECTRUM_TEXTURE_UNIT = 4
local    IMAGE_TEXTURE_UNIT = 5
local    FILTERED_IMAGE_TEXTURE_UNIT = 6
local    READOUT_TEXTURE_UNIT = 7



local FORWARD = 0
local INVERSE = 1;


local FULLSCREEN_VERTEX_SOURCE = [[
    attribute vec2 a_position;
    varying vec2 v_coordinates; //this might be phased out soon (no pun intended)
    void main (void) {
        v_coordinates = a_position * 0.5 + 0.5;
        gl_Position = vec4(a_position, 0.0, 1.0);
    }
]]

local SUBTRANSFORM_FRAGMENT_SOURCE = [[
    //precision highp float;

    const float PI = 3.14159265;

    uniform sampler2D u_input;

    uniform float u_resolution;
    uniform float u_subtransformSize;

    uniform bool u_horizontal;
    uniform bool u_forward;
    uniform bool u_normalize;

    vec2 multiplyComplex (vec2 a, vec2 b) {
        return vec2(a[0] * b[0] - a[1] * b[1], a[1] * b[0] + a[0] * b[1]);
    }

    void main (void) {

        float index = 0.0;
        if (u_horizontal) {
            index = gl_FragCoord.x - 0.5;
        } else {
            index = gl_FragCoord.y - 0.5;
        }

        float evenIndex = floor(index / u_subtransformSize) * (u_subtransformSize / 2.0) + mod(index, u_subtransformSize / 2.0);
        
        vec4 even = vec4(0.0), odd = vec4(0.0);

        if (u_horizontal) {
            even = texture2D(u_input, vec2(evenIndex + 0.5, gl_FragCoord.y) / u_resolution);
            odd = texture2D(u_input, vec2(evenIndex + u_resolution * 0.5 + 0.5, gl_FragCoord.y) / u_resolution);
        } else {
            even = texture2D(u_input, vec2(gl_FragCoord.x, evenIndex + 0.5) / u_resolution);
            odd = texture2D(u_input, vec2(gl_FragCoord.x, evenIndex + u_resolution * 0.5 + 0.5) / u_resolution);
        }

        //normalisation
        if (u_normalize) {
            even /= u_resolution * u_resolution;
            odd /= u_resolution * u_resolution;
        }

        float twiddleArgument = 0.0;
        if (u_forward) {
            twiddleArgument = 2.0 * PI * (index / u_subtransformSize);
        } else {
            twiddleArgument = -2.0 * PI * (index / u_subtransformSize);
        }
        vec2 twiddle = vec2(cos(twiddleArgument), sin(twiddleArgument));

        vec2 outputA = even.rg + multiplyComplex(twiddle, odd.rg);
        vec2 outputB = even.ba + multiplyComplex(twiddle, odd.ba);

        gl_FragColor = vec4(outputA, outputB);
		//if(!u_forward)
		//	gl_FragColor = vec4(1,0,0,1);
    }
]]

local FILTER_FRAGMENT_SOURCE = [[
    precision highp float;

    uniform sampler2D u_input;
    uniform float u_resolution;

    uniform float u_maxEditFrequency;

    uniform sampler2D u_filter;

    void main (void) {
        vec2 coordinates = gl_FragCoord.xy - 0.5;
        float xFrequency = (coordinates.x < u_resolution * 0.5) ? coordinates.x : coordinates.x - u_resolution;
        float yFrequency = (coordinates.y < u_resolution * 0.5) ? coordinates.y : coordinates.y - u_resolution;

        float frequency = sqrt(xFrequency * xFrequency + yFrequency * yFrequency);

        float gain = texture2D(u_filter, vec2(frequency / u_maxEditFrequency, 0.5)).r*2.0;
        vec4 originalPower = texture2D(u_input, gl_FragCoord.xy / u_resolution);

        gl_FragColor = originalPower * gain;

    }
]]

local POWER_FRAGMENT_SOURCE = [[
    precision highp float;

    varying vec2 v_coordinates;

    uniform sampler2D u_spectrum;
    uniform float u_resolution;

    vec2 multiplyByI (vec2 z) {
        return vec2(-z[1], z[0]);
    }

    vec2 conjugate (vec2 z) {
        return vec2(z[0], -z[1]);
    }

    vec4 encodeFloat (float v) { //hack because WebGL cannot read back floats
        vec4 enc = vec4(1.0, 255.0, 65025.0, 160581375.0) * v;
        enc = fract(enc);
        enc -= enc.yzww * vec4(1.0 / 255.0, 1.0 / 255.0, 1.0 / 255.0, 0.0);
        return enc;
    }

    void main (void) {
        vec2 coordinates = v_coordinates - 0.5;

        vec4 z = texture2D(u_spectrum, coordinates);
        vec4 zStar = texture2D(u_spectrum, 1.0 - coordinates + 1.0 / u_resolution);
        zStar = vec4(conjugate(zStar.xy), conjugate(zStar.zw));

        vec2 r = 0.5 * (z.xy + zStar.xy);
        vec2 g = -0.5 * multiplyByI(z.xy - zStar.xy);
        vec2 b = z.zw;

        float rPower = length(r);
        float gPower = length(g);
        float bPower = length(b);

        float averagePower = (rPower + gPower + bPower) / 3.0;
        gl_FragColor = encodeFloat(averagePower / (u_resolution * u_resolution));
    }
]]

local IMAGE_FRAGMENT_SOURCE = [[
    precision highp float;

    varying vec2 v_coordinates;

    uniform float u_resolution;

    uniform sampler2D u_texture;
    uniform sampler2D u_spectrum;

    void main (void) {
        vec3 image = texture2D(u_texture, v_coordinates).rgb;

        gl_FragColor = vec4(image, 1.0);
    }
]]

local function buildFramebuffer( attachment)
	local fb = ffi.new("GLuint[1]")
	glext.glGenFramebuffers(1, fb);
    local framebuffer = fb[0] --gl.createFramebuffer();
    glext.glBindFramebuffer(glc.GL_FRAMEBUFFER, framebuffer);
    glext.glFramebufferTexture2D(glc.GL_FRAMEBUFFER, glc.GL_COLOR_ATTACHMENT0, glc.GL_TEXTURE_2D, attachment, 0);
    return framebuffer;
end

local function buildTexture( unit, format, type, width, height, data, wrapS, wrapT, minFilter, magFilter) 
	local format1 = glc.GL_RGBA32F
	local pTex = ffi.new("GLuint[?]",1)
	gl.glGenTextures(1,pTex) 
    local texture = pTex[0]
    glext.glActiveTexture(glc.GL_TEXTURE0 + unit);
    gl.glBindTexture(glc.GL_TEXTURE_2D, texture);
    gl.glTexImage2D(glc.GL_TEXTURE_2D, 0, format1, width, height, 0, format, type, data);
    gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_WRAP_S, wrapS);
    gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_WRAP_T, wrapT);
    gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_MIN_FILTER, minFilter);
    gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_MAG_FILTER, magFilter);
    return texture;
end

local function bindtex(unit,tex, wrapS, wrapT, minFilter, magFilter)
	glext.glActiveTexture(glc.GL_TEXTURE0 + unit);
	gl.glBindTexture(glc.GL_TEXTURE_2D, tex);
	gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_WRAP_S, wrapS);
    gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_WRAP_T, wrapT);
    gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_MIN_FILTER, minFilter);
    gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_MAG_FILTER, magFilter);
end


local function Filterer(GL,args) 
	
	local FF = {}
	args = args or {}
	args.RES = args.RES or math.max(GL.W,GL.H)
	local m,e = math.frexp(args.RES)
	if m==0.5 then e=e-1 end
	args.RES = 2^e
	print("RESOLUTION",args.RES)
	local RESOLUTION = args.RES;
	FF.RESOLUTION = RESOLUTION
	local END_EDIT_FREQUENCY = 150.0;
	local END_EDIT_FREQUENCY2 = math.sqrt(((RESOLUTION*0.5)^2)*2)
	print("END_EDIT_FREQUENCY2",END_EDIT_FREQUENCY2)
	
	--------------
	local plugin = require"anima.plugins.plugin"
	local presets --= plugin.presets(FF)
	local serializer --= plugin.serializer(FF)
	
	local NM = GL:Dialog("fft",
	{{"unit",6,guitypes.valint,{min=0,max=6}},
	{"curv",{0,0.5,1,0.5},guitypes.curve,{pressed_on_modified=false},function(curve) FF:filter(curve.LUT,curve.LUTsize) end},
	{"bypass",false,guitypes.toggle},
	},function(this) 
		presets.draw()
		serializer.draw()
	end)


	FF = plugin.new(FF,GL,NM)
	presets = plugin.presets(FF)
	serializer = plugin.serializer(FF)
	local curve = NM.defs.curv.curve
	
------------------------
    local imageTexture,pingTexture,pongTexture,filterTexture,originalSpectrumTexture,filteredSpectrumTexture, filteredImageTexture,readoutTexture
	
	local pingFramebuffer, pongFramebuffer ,originalSpectrumFramebuffer, filteredSpectrumFramebuffer ,filteredImageFramebuffer,readoutFramebuffer
	
	local subtransformProgramWrapper, readoutProgram, imageProgram, filterProgram
	local subtransformProgramWrappervao, readoutProgramvao, imageProgramvao, filterProgramvao
	
	local old_framebuffer = ffi.new("GLuint[1]",0)
	function FF:saveoldFBO()
		gl.glGetIntegerv(glc.GL_DRAW_FRAMEBUFFER_BINDING, old_framebuffer)
	end
	function FF:setoldFBO()
	print("setoldFBO",old_framebuffer[0])
		glext.glBindFramebuffer(glc.GL_DRAW_FRAMEBUFFER, old_framebuffer[0]);
	end
	function FF:bindtexs()

		bindtex(PING_TEXTURE_UNIT,pingTexture,glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
		bindtex(PONG_TEXTURE_UNIT,pongTexture,glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
		bindtex(FILTER_TEXTURE_UNIT,filterTexture,glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
		bindtex(ORIGINAL_SPECTRUM_TEXTURE_UNIT,originalSpectrumTexture, glc.GL_REPEAT, glc.GL_REPEAT, glc.GL_NEAREST, glc.GL_NEAREST)
		bindtex(FILTERED_SPECTRUM_TEXTURE_UNIT,filteredSpectrumTexture, glc.GL_REPEAT, glc.GL_REPEAT, glc.GL_NEAREST, glc.GL_NEAREST)
		bindtex(FILTERED_IMAGE_TEXTURE_UNIT,filteredImageTexture, glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
		bindtex(READOUT_TEXTURE_UNIT,readoutTexture, glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
	end
	function FF:init()
		self:saveoldFBO()
		
        pingTexture = buildTexture( PING_TEXTURE_UNIT, glc.GL_RGBA, glc.GL_FLOAT, RESOLUTION, RESOLUTION, nil, glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
        pongTexture = buildTexture( PONG_TEXTURE_UNIT, glc.GL_RGBA, glc.GL_FLOAT, RESOLUTION, RESOLUTION, nil, glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
        filterTexture = buildTexture( FILTER_TEXTURE_UNIT, glc.GL_RGBA, glc.GL_FLOAT, RESOLUTION, 1, nil, glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
        originalSpectrumTexture = buildTexture( ORIGINAL_SPECTRUM_TEXTURE_UNIT, glc.GL_RGBA, glc.GL_FLOAT, RESOLUTION, RESOLUTION, nil, glc.GL_REPEAT, glc.GL_REPEAT, glc.GL_NEAREST, glc.GL_NEAREST)
        filteredSpectrumTexture = buildTexture( FILTERED_SPECTRUM_TEXTURE_UNIT, glc.GL_RGBA, glc.GL_FLOAT, RESOLUTION, RESOLUTION, nil, glc.GL_REPEAT, glc.GL_REPEAT, glc.GL_NEAREST, glc.GL_NEAREST)
        filteredImageTexture = buildTexture( FILTERED_IMAGE_TEXTURE_UNIT, glc.GL_RGBA, glc.GL_FLOAT, RESOLUTION, RESOLUTION, nil, glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)
        readoutTexture = buildTexture( READOUT_TEXTURE_UNIT, glc.GL_RGBA, glc.GL_UNSIGNED_BYTE, RESOLUTION, RESOLUTION, nil, glc.GL_CLAMP_TO_EDGE, glc.GL_CLAMP_TO_EDGE, glc.GL_NEAREST, glc.GL_NEAREST)

		pingFramebuffer = buildFramebuffer( pingTexture)
        pongFramebuffer = buildFramebuffer( pongTexture)
        originalSpectrumFramebuffer = buildFramebuffer( originalSpectrumTexture)
        filteredSpectrumFramebuffer = buildFramebuffer( filteredSpectrumTexture)
        filteredImageFramebuffer = buildFramebuffer( filteredImageTexture)
        readoutFramebuffer = buildFramebuffer( readoutTexture);

	subtransformProgramWrapper = GLSL:new():compile(FULLSCREEN_VERTEX_SOURCE, SUBTRANSFORM_FRAGMENT_SOURCE)
	subtransformProgramWrapper:use()
	subtransformProgramWrapper.unif.u_resolution:set{RESOLUTION}

	readoutProgram = GLSL:new():compile(FULLSCREEN_VERTEX_SOURCE, POWER_FRAGMENT_SOURCE)
	readoutProgram:use()
	readoutProgram.unif.u_spectrum:set{ORIGINAL_SPECTRUM_TEXTURE_UNIT}
	readoutProgram.unif.u_resolution:set{RESOLUTION}
	
	imageProgram = GLSL:new():compile(FULLSCREEN_VERTEX_SOURCE, IMAGE_FRAGMENT_SOURCE)
	imageProgram:use()
	imageProgram.unif.u_texture:set{FILTERED_IMAGE_TEXTURE_UNIT}

	filterProgram = GLSL:new():compile(FULLSCREEN_VERTEX_SOURCE, FILTER_FRAGMENT_SOURCE)
	filterProgram:use()
	filterProgram.unif.u_input:set{ORIGINAL_SPECTRUM_TEXTURE_UNIT}
	filterProgram.unif.u_filter:set{FILTER_TEXTURE_UNIT}
	filterProgram.unif.u_resolution:set{RESOLUTION}
	filterProgram.unif.u_maxEditFrequency:set{END_EDIT_FREQUENCY}
	
	subtransformProgramWrappervao = VAO({a_position={-1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0}},subtransformProgramWrapper
	)
	readoutProgramvao = subtransformProgramWrappervao:clone(readoutProgram)
	imageProgramvao = subtransformProgramWrappervao:clone(imageProgram)
	filterProgramvao = subtransformProgramWrappervao:clone(filterProgram)
	
	self:setoldFBO()
	end
	
    local iterations = math.log(RESOLUTION) * 2/math.log(2);
	print("iterations",iterations)
    function FF:fft(inputTextureUnit, outputFramebuffer, width, height, direction) 
		print"fft----------------"
        subtransformProgramWrapper:use()
        gl.glViewport(0, 0, RESOLUTION, RESOLUTION);
        subtransformProgramWrapper.unif.u_horizontal:set{1}
        subtransformProgramWrapper.unif.u_forward:set{(direction == FORWARD) and 1 or 0};
        for i = 0,iterations-1 do
            if (i == 0) then
                glext.glBindFramebuffer(glc.GL_FRAMEBUFFER, pingFramebuffer);
                subtransformProgramWrapper.unif.u_input:set{inputTextureUnit}
            elseif (i == iterations - 1) then
                glext.glBindFramebuffer(glc.GL_FRAMEBUFFER, outputFramebuffer);
                subtransformProgramWrapper.unif.u_input:set{PING_TEXTURE_UNIT}
            elseif (i % 2 == 1) then
                glext.glBindFramebuffer(glc.GL_FRAMEBUFFER, pongFramebuffer);
                subtransformProgramWrapper.unif.u_input:set{PING_TEXTURE_UNIT}
            else 
                glext.glBindFramebuffer(glc.GL_FRAMEBUFFER, pingFramebuffer);
                subtransformProgramWrapper.unif.u_input:set{PONG_TEXTURE_UNIT}
            end

            if (direction == INVERSE and i == 0) then
                subtransformProgramWrapper.unif.u_normalize:set{true}
            --elseif (direction == INVERSE and i == 1) then
			else
                subtransformProgramWrapper.unif.u_normalize:set{false}
            end

            if (i == (iterations / 2)) then
                subtransformProgramWrapper.unif.u_horizontal:set{0}
            end

            subtransformProgramWrapper.unif.u_subtransformSize:set{math.pow(2, (i % (iterations / 2)) + 1)}

			subtransformProgramWrappervao:draw(glc.GL_TRIANGLE_STRIP)
        end
    end

    function FF:setImage(image,w,h) 
        glext.glActiveTexture(glc.GL_TEXTURE0 + IMAGE_TEXTURE_UNIT);
		local tex = ffi.new("GLuint[1]")
		gl.glGenTextures(1, tex);
        imageTexture = tex[0]
        gl.glBindTexture(glc.GL_TEXTURE_2D, imageTexture);
       -- gl.glTexImage2D(glc.GL_TEXTURE_2D, 0, glc.GL_RGB32F, RESOLUTION, RESOLUTION, 0, glc.GL_RGB, glc.GL_UNSIGNED_BYTE, image);
	   
	   --gl.glTexImage2D(glc.GL_TEXTURE_2D, 0, glc.GL_RGB32F, w, h, 0, glc.GL_RGB, glc.GL_FLOAT, image);
	   gl.glTexImage2D(glc.GL_TEXTURE_2D, 0, glc.GL_RGBA32F, w, h, 0, glc.GL_RGB, glc.GL_FLOAT, image);
	   
        gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_WRAP_S, glc.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_WRAP_T, glc.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_MIN_FILTER, glc.GL_NEAREST);
        gl.glTexParameteri(glc.GL_TEXTURE_2D, glc.GL_TEXTURE_MAG_FILTER, glc.GL_NEAREST);

        glext.glActiveTexture(glc.GL_TEXTURE0 + ORIGINAL_SPECTRUM_TEXTURE_UNIT);
        gl.glTexImage2D(glc.GL_TEXTURE_2D, 0, glc.GL_RGBA32F, RESOLUTION, RESOLUTION, 0, glc.GL_RGBA, glc.GL_FLOAT, nil);

        self:fft(IMAGE_TEXTURE_UNIT, originalSpectrumFramebuffer, RESOLUTION, RESOLUTION, FORWARD);
    end
	local oldtexsignature
	function FF:set_texture(tex)
		if oldtexsignature and oldtexsignature==tex:get_signature() then return end
		oldtexsignature=tex:get_signature()
		print"-------------fft texture set--------------"
		self:saveoldFBO()
		if imageTexture then imageTexture:delete() end
		imageTexture = tex:resample(RESOLUTION,RESOLUTION)
		imageTexture:Bind(IMAGE_TEXTURE_UNIT)
		imageTexture:set_wrap(glc.GL_CLAMP_TO_EDGE)
		imageTexture:mag_filter(glc.GL_NEAREST)
		imageTexture:min_filter(glc.GL_NEAREST)
		
		self:bindtexs()
		glext.glActiveTexture(glc.GL_TEXTURE0 + ORIGINAL_SPECTRUM_TEXTURE_UNIT);
        gl.glTexImage2D(glc.GL_TEXTURE_2D, 0, glc.GL_RGBA32F, RESOLUTION, RESOLUTION, 0, glc.GL_RGBA, glc.GL_FLOAT, nil);
		self:fft(IMAGE_TEXTURE_UNIT, originalSpectrumFramebuffer, RESOLUTION, RESOLUTION, FORWARD);
		
		self:setoldFBO()
	end
    function FF:filter(filterArray, length) 
		print"fft:filter"
		self:saveoldFBO()
		
		self:bindtexs()
		
        glext.glActiveTexture(glc.GL_TEXTURE0 + FILTER_TEXTURE_UNIT);
        gl.glTexImage2D(glc.GL_TEXTURE_2D, 0, glc.GL_RED, length, 1, 0, glc.GL_RED, glc.GL_FLOAT, filterArray);

        filterProgram:use()

        glext.glBindFramebuffer(glc.GL_FRAMEBUFFER, filteredSpectrumFramebuffer);
        gl.glViewport(0, 0, RESOLUTION, RESOLUTION);
		filterProgramvao:draw(glc.GL_TRIANGLE_STRIP)
		
        self:fft(FILTERED_SPECTRUM_TEXTURE_UNIT, filteredImageFramebuffer, RESOLUTION, RESOLUTION, INVERSE);
		--self:fft(ORIGINAL_SPECTRUM_TEXTURE_UNIT, filteredImageFramebuffer, RESOLUTION, RESOLUTION, INVERSE);

       -- self:output();
	   self:setoldFBO()
    end

    function FF:output() 
		self:output2(NM.unit)
    end
	function FF:output2(nn) 
		--ut.Clear()
		if nn==6 or nn==5 then
			local xoff,yoff= 0,0
			local w,h = GL.W,GL.H
			if GL.H > GL.W then
				xoff = (GL.W-GL.H)*0.5
				w = GL.H
			else
				yoff = (GL.H-GL.W)*0.5
				h = GL.W
			end
			gl.glViewport(xoff,yoff,w,h)
		else
			gl.glViewport(getAspectViewport(GL.W,GL.H,RESOLUTION, RESOLUTION));
		end
        imageProgram:use()
		imageProgram.unif.u_resolution:set{RESOLUTION}
		imageProgram.unif.u_texture:set{nn}
		imageProgram.unif.u_spectrum:set{FILTERED_SPECTRUM_TEXTURE_UNIT}
		imageProgramvao:draw(glc.GL_TRIANGLE_STRIP)
    end
	function FF:process(texture)
		print"fftprocess"
		if NM.bypass then texture:drawcenter();return end
		self:set_texture(texture)
		self:filter(curve.LUT,curve.LUTsize)
		self:output()
	end
	GL:add_plugin(FF)
	return FF
end

--[=[
require"anima"
RES=400
GL = GLcanvas{H=RES,W=RES,profile="CORE",DEBUG=true,use_log=false}

NM = GL:Dialog("test",{{"orig",false,guitypes.toggle}})
local vicim = require"anima.vicimag"
local image,tex,fft,fbo
function GL.init()
	GLSL.default_version = "#version 330\n"

	image = vicim.load_im([[C:\luaGL\media\fandema1.tif]])
	
	tex = image:totex(GL)
	fbo = tex:make_fbo()
	--tex = tex:resample_fac(0.25)
	GL:set_WH(tex.width,tex.height)
	fft = Filterer(GL)--,{RES=RES})
	--fft:set_texture(tex)
	--print_glinfo(GL)
	GL:DirtyWrap()
end

function GL.draw(t,w,h)
	ut.Clear()
	if NM.orig then
		tex:drawcenter()
	else
		fft:process_fbo(fbo,tex)
		fbo:tex():drawcenter()
		--fft:output()
	end
end
GL:start()
--]=]

---[=[
require"anima"
local GL = GLcanvas{H=700,W=700}

local NM = GL:Dialog("test",{
{"freq",1,guitypes.val,{min=1,max=500}}
})
local tproc,chain,fft
function GL.init()
	tproc = require"anima.plugins.texture_processor"(GL,0,NM)
	tproc:set_process[[vec4 process(vec2 pos){
		return vec4(sin(pos.x*2*3.14159*freq)*0.5+0.5);
	}]]
	fft = Filterer(GL)
	local tex = GL:Texture()
	local tex2 = tex:resample(2,2)
	chain = tex:make_chain{tproc,fft}
	GL:DirtyWrap()
end

function GL.draw(t,w,h)
	ut.Clear()
	--tproc:process{}
	chain:process({})
	chain:tex():drawcenter()
end

GL:start()
--]=]


return Filterer