const fs=require('node:fs'),path=require('node:path');
module.exports=()=>{const root=path.resolve(__dirname,'..');return fs.readFileSync(path.join(root,'index.html'),'utf8').replace(/<script defer src="\/portal-app\.js[^"]*"><\/script>/,()=>'<script>'+fs.readFileSync(path.join(root,'portal-app.js'),'utf8')+'</script>');};
