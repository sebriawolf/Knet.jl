"""
S2S(net::Function) implements the sequence to sequence model from:
Sutskever, I., Vinyals, O., & Le, Q. V. (2014). Sequence to sequence
learning with neural networks. Advances in neural information
processing systems, 3104-3112.  The @knet function `net` is duplicated
to create an encoder and a decoder.  See `S2SData` for data format.
"""
immutable S2S <: Model; encoder; decoder; params;
    function S2S(kfun::Function; o...)
        enc = Net(encoder; o..., f=kfun)
        dec = Net(decoder; o..., f=kfun)
        new(enc, dec, vcat(params(enc), params(dec)))
    end
end

@knet function encoder(word; f=nothing, hidden=0, o...)
    wvec = wdot(word; o..., out=hidden)
    hvec = f(wvec; o..., out=hidden)
end

@knet function decoder(word; f=nothing, hidden=0, vocab=0, o...)
    hvec = encoder(word; o..., f=f, hidden=hidden)
    tvec = wbf(hvec; out=vocab, f=soft)
end

params(m::S2S)=m.params
reset!(m::S2S; o...)=(reset!(m.encoder; o...);reset!(m.decoder; o...))


function train(m::S2S, data, loss; getloss=true, getnorm=true, gclip=0, gcheck=0, o...)
    gcheck>0 && Base.warn_once("s2s.gradcheck has not been implemented, ignoring option. (TODO)")
    numloss = sumloss = maxwnorm = maxgnorm = 0
    decoding = false
    ystack = Any[]
    reset!(m; o...)
    for item in data
        (x,ygold) = item2xy(item)
        if decoding && ygold == nothing # the next sentence started
            (maxwnorm, maxgnorm) = bptt(m, ystack, loss; getnorm=getnorm, gclip=gclip, maxwnorm=maxwnorm, maxgnorm=maxgnorm, o...)
            @assert isempty(ystack) && m.encoder.sp == 0 && m.decoder.sp == 0
            reset!(m; o...)
            decoding = false
        end
        if !decoding && ygold != nothing
            copyforw!(m)
            decoding = true
        end
        if decoding && ygold != nothing
            ypred = forw(m.decoder, x...; trn=true, seq=true, o...)
            getloss && (sumloss += loss(ypred, ygold); numloss += 1)
            push!(ystack, copy(ygold))
        end
        if !decoding && ygold == nothing
            forw(m.encoder, x...; trn=true, seq=true, o...)
        end
    end
    # For the last sentence
    (maxwnorm, maxgnorm) = bptt(m, ystack, loss; getnorm=getnorm, gclip=gclip, maxwnorm=maxwnorm, maxgnorm=maxgnorm, o...)
    return (sumloss/numloss, maxwnorm, maxgnorm)
end

function test(m::S2S, data, loss; o...)
    numloss = sumloss = 0
    decoding = false
    reset!(m; o...)
    for item in data
        (x,ygold) = item2xy(item)
        if decoding && ygold == nothing # the next sentence started
            reset!(m; o...)
            decoding = false
        end
        if !decoding && ygold != nothing # output sequence started
            copyforw!(m)
            decoding = true
        end
        if decoding && ygold != nothing # keep decoding
            ypred = forw(m.decoder, x...; trn=false, seq=true, o...)
            sumloss += loss(ypred, ygold)
            numloss += 1
        end
        if !decoding && ygold == nothing # keep encoding
            forw(m.encoder, x...; trn=false, seq=true, o...)
        end
    end
    sumloss / numloss
end

function bptt(m::S2S, ystack, loss; getnorm=true, gclip=0, maxwnorm=0, maxgnorm=0, o...)
    # @assert m.encoder.sp == m.decoder.sp # this does not work when encoder does not have output
    while !isempty(ystack)
        ygold = pop!(ystack)
        back(m.decoder, ygold, loss; seq=true, o...)
    end
    @assert m.decoder.sp == 0
    copyback!(m)
    while m.encoder.sp > 0
        back(m.encoder; seq=true, o...)
    end
    (getnorm || gclip>0) && (g = gnorm(m); g > maxgnorm && (maxgnorm = g))
    update!(m; gclip=(g > gclip > 0 ? gclip/g : 0), o...)
    getnorm && (w = wnorm(m); w > maxwnorm && (maxwnorm = w))
    (maxwnorm, maxgnorm)
end

function copyforw!(m::S2S)
    for n=1:nops(m.encoder)
        if forwref(m.encoder, n)
            # m.decoder.out0[n] == nothing && (m.decoder.out0[n] = similar(m.encoder.out[n]))
            # m.decoder.out[n] = copy!(m.decoder.out0[n], m.encoder.out[n])
            m.decoder.out[n] = m.decoder.out0[n] = m.encoder.out[n]
        end
    end
end

function copyback!(m::S2S)
    for n=1:nops(m.encoder)
        if forwref(m.encoder, n)
            # m.encoder.dif0[n] == nothing && (m.encoder.dif0[n] = similar(m.decoder.dif[n]))
            # m.encoder.dif[n] = copy!(m.encoder.dif0[n], m.decoder.dif[n])
            m.encoder.dif[n] = m.encoder.dif0[n] = m.decoder.dif[n]
        end
    end
end


"""
S2SData(sourcefile, targetfile; batch=20, ftype=Float32, dense=false, dict1=Dict(), dict2=Dict())
creates a data generator that can be used with an S2S model.  The
inputs sourcefile and targetfile should contain the desired source and
target sequences with one sequence per line consisting of space
separated tokens.
    
The following transformations are performed by an S2SData generator:

* sequences are minibatched according to the batch argument.
* sequences in a minibatch padded to all be the same length.
* sequences are sorted by length to minimize padding.
* the source sequences are generated in reverse order.
* source tokens are presented as (x,nothing) pairs
* target tokens are presented as (x[t-1],x[t]) pairs

Example:
```
sourcefile:
The dog ran
The next sentence

targetfile:
El perror corrio
La frase siguiente
```
order of items generated by S2SData(sourcefile, targetfile):
```
(<s>,nothing)
(ran,nothing)
(dog,nothing)
(The,nothing)
(<s>,El)
(El,perror)
(perror,corrio)
(corrio,<s>)
(<s>,nothing)
(sentence,nothing)
(next,nothing)
(The,nothing)
(<s>,La)
(La,frase)
(frase,siguiente)
(siguiente,<s>)
```
(except each word will be represented by a one-hot vector, and with
minibatch > 1, words from multiple sentences will be concatented in 
a matrix.)

Note that the end-of-sentence markers <s> are automatically inserted
by the S2SData generator and are not present in the sourcefile or the
targetfile.  The S2S model switches between encoding and decoding
using y=nothing as an indicator.    
"""
type S2SData; data1; data2; dict1; dict2; batch; ftype; dense; x; y; end

function S2SData(file1::AbstractString, file2::AbstractString; batch=20, ftype=Float32, dense=false,
                 dict1=Dict{Any,Int32}(), dict2=Dict{Any,Int32}())
    data1 = loadseq(file1, dict1)
    data2 = loadseq(file2, dict2)
    @assert length(data1) == length(data2)
    sorted = sortperm(data1, by=length)
    data1 = data1[sorted]
    data2 = data2[sorted]
    S2SData(data1, data2, dict1, dict2, batch, ftype, dense, nothing, nothing)
end

const eosstr = "<s>"
const eos = 1

function loadseq(fname::AbstractString, dict=Dict{Any,Int32}())
    data = Vector{Int32}[]
    isempty(dict) && (dict[eosstr]=eos)
    open(fname) do f
        for l in eachline(f)
            sent = Int32[]
            for w in split(l)
                push!(sent, get!(dict, w, 1+length(dict)))
            end
            push!(data, sent)
        end
    end
    info("Read $fname[ns=$(length(data)),nw=$(mapreduce(length,+,data)),nd=$(length(dict))]")
    return data
end

import Base: start, done, next

# the state consists of (nbatch, nword, decode), where nbatch is the
# number of batches completed, and nword is the number of words
# completed in the current batch, and decode is a boolean indicating
# whether we are in the decoding phase.
function next(d::S2SData, state)
    (nbatch, nword, decode) = state 
    s1 = d.batch * nbatch + 1
    s2 = d.batch * (nbatch + 1)
    if !decode                  # gen data1[s1:s2] in reverse for encoding
        data = sub(d.data1, s1:s2)
        slen = 1 + maximum(map(length, data))
        for sent=1:length(data)
            xword = (slen-nword <= length(data[sent]) ? data[sent][slen-nword] : eos)
            setrow!(d.x, xword, sent)
        end
        nword += 1
        nword == slen && (nword = 0; decode = true)
        return ((d.x, nothing), (nbatch, nword, decode))
    else                        # gen data2[s1:s2] for decoding
        data = sub(d.data2, s1:s2)
        slen = 1 + maximum(map(length, data))
        for sent=1:length(data)
            xword = (1 <= nword <= length(data[sent]) ? data[sent][nword] : eos)
            yword = (1 <= nword+1 <= length(data[sent]) ? data[sent][nword+1] : eos)
            setrow!(d.x, xword, sent)
            setrow!(d.y, yword, sent)
        end
        nword += 1
        nword == slen && (nbatch += 1; nword = 0; decode = false)
        return ((d.x, d.y), (nbatch, nword, decode))
    end
end

setrow!(x::SparseMatrixCSC,i,j)=(x.rowval[j] = i)
setrow!(x::Array,i,j)=(x[:,j]=0; x[i,j]=1)

# we stop if there is not enough data for another full batch.
# TODO: add warning if we are leave some data out
function done(d::S2SData,state)
    (nbatch, nword, decode) = state
    (nbatch+1)*d.batch > length(d.data1)
end

# allocate the batch arrays if necessary
function start(d::S2SData)
    maxdict = max(length(d.dict1), length(d.dict2))
    if d.x == nothing || size(d.x) != (maxdict, d.batch)
        if d.dense
            d.x = zeros(d.ftype, maxdict, d.batch)
            d.y = zeros(d.ftype, maxdict, d.batch)
        else
            d.x = speye(d.ftype, maxdict, d.batch)
            d.y = speye(d.ftype, maxdict, d.batch)
        end
    end
    return (0, 0, false)
end

# FAQ:
#
# Q: How do we handle the transition?  Is eos fed to the encoder or the decoder?
#   It looks like the decoder from the picture.  We handle switch using the state variable.
# Q: Do we feed one best, distribution, or gold for word[t-1] to the decoder?
#   Gold during training, one-best output during testing?  (could also try the actual softmax output)
# Q: How do we handle the sequence ending?  How is the training signal passed back?
#   gold outputs, bptt first through decoder then encoder, triggered by output eos (or data=nothing when state=decode)
# Q: input reversal?
#   handled by the data generator
# Q: batching and padding of inputs of different length?
#   handled by the data generator
# Q: data format? <eos> ran dog The <eos> el perror corrio <eos> sentence next The <eos> its spanish version <eos> ...
#   so data does not need to have x/y pairs, just a y sequence for training (and testing?).
#   we could use nothings to signal eos, but we do need an actual encoding for <eos>
#   so don't replace <eos>, keep it, just insert nothings at the end of each sentence.
#   except in the very beginning, a state variable keeps track of encoding vs decoding
# Q: how about the data generator gives us x/y pairs:
#   during encoding we get x/nothing as desired input/output.
#   during decoding we get x[t-1]/x[t] as desired input/output.
#   this is more in line with what we did with rnnlm,
#   also in line with models not caring about how data is formatted, only desired input/output.
#   in this design we can distinguish encoding/decoding by looking at output
# Q: test time: 
#   encode proceeds normally
#   when we reach nothing, we switch to decoding
#   when we reach nothing again, we perform bptt (need stack for gold output, similar to rnnlm)
#   the first token to decoder gets fed from the gold (presumably <eos>)
#   the subsequent input tokens come from decoder's own output
#   second nothing resets and switches to encoding, no bptt
# Q: beam search?
#   don't need this for training or test perplexity
#   don't need this for one best greedy output
#   it will make minibatching more difficult
#   this is a problem for predict (TODO)
