export default async function handler(req,res){
  if(req.method!=='POST') return res.status(405).json({error:'Método não permitido'});
  if(!process.env.OPENAI_API_KEY) return res.status(503).json({error:'IA ainda não configurada'});
  const {message,context='',manual=[]}=req.body||{};
  if(!message) return res.status(400).json({error:'Digite uma pergunta'});
  const guide=Array.isArray(manual)?manual.slice(0,120).map(x=>Array.isArray(x)?x.join(': '):String(x)).join('\n'):'';
  const instructions='Você é o Assistente do sistema Gestão Escolar Frota. Responda em português brasileiro, de forma simples, natural e objetiva. Ajude o usuário a operar o sistema passo a passo. Use o manual fornecido como fonte principal e não invente telas, botões ou dados. Se faltar informação, diga isso e peça o detalhe necessário. Contexto anterior: '+context+'\n\nMANUAL DO SISTEMA:\n'+guide;
  try{
    const r=await fetch('https://api.openai.com/v1/responses',{method:'POST',headers:{'Authorization':'Bearer '+process.env.OPENAI_API_KEY,'Content-Type':'application/json'},body:JSON.stringify({model:'gpt-5.6-luna',instructions,input:message,max_output_tokens:500})});
    const j=await r.json();
    if(!r.ok) return res.status(r.status).json({error:j?.error?.message||'Falha na IA'});
    const answer=j.output_text||(j.output||[]).flatMap(o=>o.content||[]).map(x=>x.text||'').join('').trim();
    return res.status(200).json({answer:answer||'Não consegui formular a resposta.'});
  }catch(e){return res.status(500).json({error:'Falha ao consultar a IA'});}
}