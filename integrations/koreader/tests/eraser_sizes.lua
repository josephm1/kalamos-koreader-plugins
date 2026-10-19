local tools=require('inktools')
local strokes={{points={{0,0},{40,0}},width=2},{points={{0,12},{40,12}},width=2}}
local gesture={{20,7},{21,7}}
-- Notes size means diameter; native and Lua store its half as the erase radius.
assert(#tools.erase(strokes,gesture,'stroke',3)==2)
assert(#tools.erase(strokes,gesture,'stroke',6)==1)
assert(#tools.erase(strokes,gesture,'stroke',10)==0)
local pixel=tools.erase({strokes[1]},{{20,0}},'track',3)
assert(#pixel==2 and pixel[1].points[#pixel[1].points][1]<20 and pixel[2].points[1][1]>20)
assert(#tools.erase(strokes,{{-5,-5},{45,-5},{45,5},{-5,5}},'range',10)==1)
print('Notes eraser: small/medium/large radius, pixel splitting and erasing-lasso deletion passed')

local sparse={{points={{0,10},{100,10}},width=2}}
assert(#tools.erase(sparse,{{40,0},{60,0},{60,20},{40,20}},'range',10)==0)
assert(#tools.erase(sparse,{{40,30},{60,30},{60,50},{40,50}},'range',10)==1)
print('Erasing lasso: sparse segment crossing loop is removed; missed loop preserves ink passed')
