#version 450
#extension GL_ARB_shader_ballot : require
#extension GL_ARB_gpu_shader_int64 : require
layout(location=0) in vec4 p;
layout(location=0) out vec4 o;
void main(){
  uint64_t b = ballotARB(p.x > 0.0);
  float f = readFirstInvocationARB(p.y) + readInvocationARB(p.z, 0u);
  o = vec4(float(uint(b)), f, float(gl_SubGroupInvocationARB), float(uint(gl_SubGroupEqMaskARB)));
  gl_Position = p;
}
